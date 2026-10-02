import Foundation
import CoreFoundation
#if canImport(Darwin)
import Darwin
#endif

/// A fresh host observation, never a second pool of GPU RAM on Apple Silicon.
public struct LocalModelMemory: Codable, Equatable, Sendable {
    public let physicalBytes: UInt64
    public let availableBytes: UInt64
    public let pressure: Int
    public static let gib: UInt64 = 1_073_741_824

    public init(physicalBytes: UInt64, availableBytes: UInt64, pressure: Int) {
        self.physicalBytes = physicalBytes
        self.availableBytes = min(physicalBytes, availableBytes)
        self.pressure = pressure
    }

    public static func current() -> Self {
        let total = ProcessInfo.processInfo.physicalMemory
        #if canImport(Darwin)
        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return .init(physicalBytes: total, availableBytes: 0, pressure: -1) }
        let pages = reclaimablePages(free: UInt64(stats.free_count), inactive: UInt64(stats.inactive_count),
                                     anonymous: UInt64(stats.internal_page_count))
        return .init(physicalBytes: total, availableBytes: pages * UInt64(vm_kernel_page_size),
                     pressure: ManagedLocalModel.hostMemoryPressure())
        #elseif os(Linux)
        guard let raw = try? String(contentsOfFile: "/proc/meminfo"),
              let line = raw.split(separator: "\n").first(where: { $0.hasPrefix("MemAvailable:") }),
              let kib = UInt64(line.split(whereSeparator: { $0.isWhitespace }).dropFirst().first ?? "")
        else { return .init(physicalBytes: total, availableBytes: 0, pressure: -1) }
        let available = kib * 1024
        return .init(physicalBytes: total, availableBytes: available,
                     pressure: available >= max(Self.gib, total / 5) ? 1 : 2)
        #else
        return .init(physicalBytes: total, availableBytes: 0, pressure: -1)
        #endif
    }

    /// Mach free_count already includes speculative pages. The kernel reports total anonymous
    /// pages, not their inactive subset: subtract all of them for a conservative lower bound on
    /// file-backed inactive pages. Never credit compressed, swap, or overlapping purgeable pages.
    static func reclaimablePages(free: UInt64, inactive: UInt64, anonymous: UInt64) -> UInt64 {
        free + (inactive > anonymous ? inactive - anonymous : 0)
    }

    /// Keep at least half of physical memory outside this request, and an additional GiB
    /// of currently available memory for desktop activity. Swap/disk space is never capacity.
    public var requestBudgetBytes: UInt64 {
        guard pressure == 1, physicalBytes >= 4 * Self.gib, availableBytes > Self.gib else { return 0 }
        return min(physicalBytes / 2, availableBytes - Self.gib)
    }

    public var admissionBlocker: String? {
        if pressure != 1 { return "host memory pressure is elevated or its measurement is unavailable" }
        if physicalBytes < 4 * Self.gib { return "physical RAM is below the local runtime minimum" }
        if availableBytes <= Self.gib { return "insufficient available memory after reserving desktop headroom" }
        return nil
    }
}

/// Estimates are admission evidence, not a guarantee of throughput or a measured peak RSS.
public struct LocalModelAdmission: Encodable, Equatable, Sendable {
    public let model: String
    public let memory: LocalModelMemory
    public let contextTokens: Int
    public let weightsBytes: UInt64?
    public let kvBytes: UInt64?
    public let workspaceBytes: UInt64?
    public let requiredBytes: UInt64?
    public let decision: String
    public let reason: String
    public let sharding: String = "single_host_no_memory_sharding"
    public let nextStep: String

    public var admitted: Bool { decision == "load_on_demand" }
    public var providerError: AIProviderError {
        .configuration("local model capacity unavailable: \(reason); \(nextStep)")
    }

    public static func blocked(model: String, memory: LocalModelMemory, context: Int, reason: String,
                               weights: UInt64? = nil, kv: UInt64? = nil, workspace: UInt64? = nil) -> Self {
        .init(model: model, memory: memory, contextTokens: context, weightsBytes: weights,
              kvBytes: kv, workspaceBytes: workspace, requiredBytes: total(weights, kv, workspace),
              decision: "fallback_required", reason: reason,
              nextStep: "Use a smaller model or an already permitted cloud provider. GGUF file splitting adds no RAM; a cluster requires another machine.")
    }

    private static func total(_ weights: UInt64?, _ kv: UInt64?, _ workspace: UInt64?) -> UInt64? {
        guard let weights, let kv, let workspace else { return nil }
        return weights + kv + workspace // all inputs bounded below
    }

    static func positive(_ value: Any?, max: UInt64) -> UInt64? {
        // Reject booleans, fractions, negatives and overflow from untrusted API metadata.
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite, number.doubleValue >= 1, number.doubleValue <= Double(max),
              number.doubleValue.rounded(.down) == number.doubleValue else { return nil }
        return number.uint64Value
    }

    public static func evaluate(model: String, weights: UInt64, info: [String: Any], context: Int,
                                memory: LocalModelMemory) -> Self {
        func no(_ reason: String) -> Self {
            blocked(model: model, memory: memory, context: context, reason: reason, weights: weights)
        }
        guard (256...131_072).contains(context), weights > 0, weights <= 1024 * LocalModelMemory.gib else {
            return no("invalid context or total model size")
        }
        guard memory.requestBudgetBytes > 0 else { return no(memory.admissionBlocker ?? "insufficient available memory") }
        guard weights < memory.requestBudgetBytes else { return no("total model weights exceed the current single-host memory budget") }
        // Hybrid/recurrent/MLA and multimodal caches need their own measured estimator. Do not
        // pretend the ordinary GQA formula works for every model, or estimate from its name.
        guard let architecture = info["general.architecture"] as? String,
              ["llama", "qwen2", "qwen3", "gemma", "gemma2", "gemma3", "phi2", "phi3"].contains(architecture)
        else { return no("model architecture has no supported memory estimator") }
        func field(_ key: String, _ maximum: UInt64) -> UInt64? {
            positive(info["\(architecture).\(key)"], max: maximum)
        }
        guard let layers = field("block_count", 1024),
              let heads = field("attention.head_count", 4096),
              let kvHeads = field("attention.head_count_kv", 4096), kvHeads <= heads,
              let embedding = field("embedding_length", 1_048_576), embedding % heads == 0,
              let maxContext = field("context_length", 16_777_216), UInt64(context) <= maxContext
        else { return no("incomplete architecture metadata or context exceeds the model limit") }
        let key = info["\(architecture).attention.key_length"] == nil
            ? embedding / heads : field("attention.key_length", 65_536)
        let value = info["\(architecture).attention.value_length"] == nil
            ? embedding / heads : field("attention.value_length", 65_536)
        guard let key, let value, key <= 65_536, value <= 65_536 else {
            return no("invalid attention dimensions")
        }
        // F16 K and V: do not credit q8/q4 savings unless the backend proves it actually used
        // them. Count every layer even for sliding-window attention. One serialized request.
        let kv = UInt64(context) * layers * kvHeads * (key + value) * 2
        let workspace = max(LocalModelMemory.gib, weights / 5)
        let required = weights + kv + workspace
        guard required <= memory.requestBudgetBytes else {
            return blocked(model: model, memory: memory, context: context,
                           reason: "weights, context cache and workspace exceed the current single-host memory budget",
                           weights: weights, kv: kv, workspace: workspace)
        }
        return .init(model: model, memory: memory, contextTokens: context, weightsBytes: weights,
                     kvBytes: kv, workspaceBytes: workspace, requiredBytes: required,
                     decision: "load_on_demand", reason: "estimated working set fits the current memory budget",
                     nextStep: "Run one request with bounded context and unload afterward. Recheck before every load.")
    }
}
