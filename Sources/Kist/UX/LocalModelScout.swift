import Foundation

struct LocalModelScoutCandidate: Codable, Equatable, Sendable {
    var id: String
    var modelID: String
    var provider: String
    var source: String
    var taskFit: [String]
    var estimatedDiskGB: Int
    var estimatedMemoryGB: Int
    var quantization: String
    var score: Int
    var why: String
    var licenseGate: String
    var templateGate: String
    var risks: [String]
    var onboardingSteps: [String]
    var evalPlan: [String]
}

struct LocalModelScoutReport: Equatable, Sendable {
    var path: String
    var text: String
    var objective: String
    var hardwareMemoryGB: Int
    var candidates: [LocalModelScoutCandidate]
    var seededTasks: Int
    var memoryRecords: Int
    var writeSucceeded: Bool
    var writeError: String?
}

enum LocalModelScout {
    static func plan(objective rawObjective: String,
                     hardwareMemoryGB: Int = defaultMemoryGB()) -> [LocalModelScoutCandidate] {
        let objective = rawObjective.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = objective.lowercased()
        let wantsCode = containsAny(lower, ["code", "coder", "swift", "typescript", "javascript", "react", "repo", "refactor", "bug", "test"])
        let wantsReasoning = containsAny(lower, ["reason", "planner", "architecture", "critic", "review", "math", "decision"])
        let wantsRetrieval = containsAny(lower, ["memory", "retrieval", "search", "embed", "embedding", "index", "rag"])
        let wantsTiny = containsAny(lower, ["tiny", "small", "fast", "cheap", "low latency", "offline"])

        var candidates: [LocalModelScoutCandidate] = []
        if !wantsRetrieval || wantsCode || wantsReasoning {
            candidates.append(candidate(
                id: "qwen35-9b-ollama", modelID: "qwen3.5:9b-q4_K_M", provider: "ollama",
                source: "https://huggingface.co/Qwen/Qwen3.5-9B · GGUF runtime: https://ollama.com/library/qwen3.5:9b-q4_K_M",
                taskFit: ["code", "tool calling", "general assistant"], estimatedDiskGB: 7,
                estimatedMemoryGB: 10, quantization: "Q4_K_M; 16K runtime context",
                score: wantsTiny ? 78 : 95,
                why: "Native tools and a bounded coding fix passed on the 16 GB M4; difficult planning can still need cloud fallback. Prefer at least 16 GB host RAM.",
                objective: objective))
            candidates.append(candidate(
                id: "qwen35-4b-ollama", modelID: "qwen3.5:4b-q4_K_M", provider: "ollama",
                source: "https://huggingface.co/Qwen/Qwen3.5-4B · GGUF runtime: https://ollama.com/library/qwen3.5:4b-q4_K_M",
                taskFit: ["fast utility", "summary", "small assistant"], estimatedDiskGB: 4,
                estimatedMemoryGB: 6, quantization: "Q4_K_M",
                score: wantsTiny ? 92 : 83,
                why: "Smaller current-family candidate for tight memory and latency. Not yet qualified as the production coding model; onboard and benchmark first.",
                objective: objective))
        }
        if wantsCode {
            candidates.append(qwenCoderMLX(memoryGB: hardwareMemoryGB, objective: objective))
            candidates.append(qwenCoderOllama(memoryGB: hardwareMemoryGB, objective: objective))
            if hardwareMemoryGB >= 24 {
                candidates.append(qwenCoder14B(memoryGB: hardwareMemoryGB, objective: objective))
            }
        }
        if wantsReasoning {
            candidates.append(qwenInstruct(memoryGB: hardwareMemoryGB, objective: objective))
        }
        if wantsRetrieval {
            candidates.append(embeddingCompanion(memoryGB: hardwareMemoryGB, objective: objective))
        }
        if wantsTiny || candidates.isEmpty {
            candidates.append(llamaSmallMLX(memoryGB: hardwareMemoryGB, objective: objective))
            candidates.append(phiMiniOllama(memoryGB: hardwareMemoryGB, objective: objective))
        }
        if !wantsTiny && candidates.count < 3 {
            candidates.append(llamaSmallMLX(memoryGB: hardwareMemoryGB, objective: objective))
        }
        return candidates
            .map { adjustedForHardware($0, memoryGB: hardwareMemoryGB) }
            .sorted { lhs, rhs in
                if lhs.score != rhs.score { return lhs.score > rhs.score }
                return lhs.estimatedMemoryGB < rhs.estimatedMemoryGB
            }
            .prefix(5)
            .map { $0 }
    }

    static func render(objective: String,
                       hardwareMemoryGB: Int,
                       candidates: [LocalModelScoutCandidate],
                       reportPath: String,
                       seededTasks: Int,
                       memoryRecords: Int) -> String {
        var lines = [
            "# Safe Local Model Scout",
            "",
            "Objective: \(objective.isEmpty ? "local model acquisition" : objective)",
            "Host memory estimate: \(hardwareMemoryGB) GB",
            "",
            "## Safety Policy",
            "- This is a scout report only. It does not download, install, trust, or promote any model.",
            "- Every candidate must pass license/provenance, size, template, sandbox, benchmark, and rollback gates.",
            "- A local model can become default only after repeated task-family wins are recorded as benchmark or live-eval evidence.",
            "",
            "## Candidate Matrix",
        ]
        for candidate in candidates {
            lines += [
                "",
                "### \(candidate.modelID)",
                "Provider: \(candidate.provider)",
                "Source: \(candidate.source)",
                "Score: \(candidate.score)/100",
                "Task fit: \(candidate.taskFit.joined(separator: ", "))",
                "Size: ~\(candidate.estimatedDiskGB) GB disk, ~\(candidate.estimatedMemoryGB) GB memory",
                "Quantization: \(candidate.quantization)",
                "Why: \(candidate.why)",
                "License gate: \(candidate.licenseGate)",
                "Template gate: \(candidate.templateGate)",
                "Risks:",
            ]
            lines += candidate.risks.map { "- \($0)" }
            lines += ["Onboarding steps:"]
            lines += candidate.onboardingSteps.map { "- \($0)" }
            lines += ["Eval plan:"]
            lines += candidate.evalPlan.map { "- \($0)" }
        }
        lines += [
            "",
            "## Promotion Gate",
            "Do not route production work to a candidate until:",
            "- `kist --inspect-model` has identified stops or the provider/server has a proven stop profile.",
            "- `kist --onboard` returns ready or an explicitly accepted partial verdict.",
            "- `/bench` or `/eval` records task-family wins against the current cloud/default baseline.",
            "- Captain records the result in learning memory and keeps rollback to the previous model.",
            "",
            "## Artifacts",
            "Report: \(reportPath)",
            "Seeded tasks: \(seededTasks)",
            "Knowledge index records: \(memoryRecords)"
        ]
        return lines.joined(separator: "\n")
    }

    static func defaultMemoryGB() -> Int {
        let bytes = ProcessInfo.processInfo.physicalMemory
        guard bytes > 0 else { return 16 }
        let gb = Double(bytes) / 1_073_741_824
        return max(4, Int(gb.rounded()))
    }

    private static func qwenCoderMLX(memoryGB: Int, objective: String) -> LocalModelScoutCandidate {
        candidate(id: "qwen-coder-7b-mlx",
                  modelID: "mlx-community/Qwen2.5-Coder-7B-Instruct-4bit",
                  provider: "mlx",
                  source: "Hugging Face MLX community model; verify current repo, license, and files before download.",
                  taskFit: ["code", "refactor", "tests", "agent worker"],
                  estimatedDiskGB: 5,
                  estimatedMemoryGB: 10,
                  quantization: "4-bit MLX",
                  score: 88,
                  why: "Strong small-code candidate for local worker/coder tasks when MLX server is available.",
                  objective: objective)
    }

    private static func qwenCoderOllama(memoryGB: Int, objective: String) -> LocalModelScoutCandidate {
        candidate(id: "qwen-coder-7b-ollama",
                  modelID: "qwen2.5-coder:7b",
                  provider: "ollama",
                  source: "Ollama registry; verify tag, license, and upstream provenance before pull.",
                  taskFit: ["code", "shell planning", "repo Q&A"],
                  estimatedDiskGB: 5,
                  estimatedMemoryGB: 10,
                  quantization: "Ollama default quantization for tag",
                  score: 84,
                  why: "Practical local baseline because Ollama manages model storage and serving.",
                  objective: objective)
    }

    private static func qwenCoder14B(memoryGB: Int, objective: String) -> LocalModelScoutCandidate {
        candidate(id: "qwen-coder-14b-mlx",
                  modelID: "mlx-community/Qwen2.5-Coder-14B-Instruct-4bit",
                  provider: "mlx",
                  source: "Hugging Face MLX community model; verify hardware fit and current repo before download.",
                  taskFit: ["larger code review", "architecture", "multi-file refactor"],
                  estimatedDiskGB: 10,
                  estimatedMemoryGB: 18,
                  quantization: "4-bit MLX",
                  score: 90,
                  why: "Better coding headroom than 7B if memory allows; keep behind benchmark gates.",
                  objective: objective)
    }

    private static func qwenInstruct(memoryGB: Int, objective: String) -> LocalModelScoutCandidate {
        candidate(id: "qwen-instruct-7b",
                  modelID: "qwen2.5:7b-instruct",
                  provider: "ollama",
                  source: "Ollama registry or upstream Hugging Face equivalent; verify exact tag before pull.",
                  taskFit: ["planning", "summarization", "review", "low-risk reasoning"],
                  estimatedDiskGB: 5,
                  estimatedMemoryGB: 10,
                  quantization: "Ollama default quantization for tag",
                  score: 80,
                  why: "General local reasoning candidate for cheap planning and summaries after eval proof.",
                  objective: objective)
    }

    private static func llamaSmallMLX(memoryGB: Int, objective: String) -> LocalModelScoutCandidate {
        candidate(id: "llama-3-2-3b-mlx",
                  modelID: "mlx-community/Llama-3.2-3B-Instruct-4bit",
                  provider: "mlx",
                  source: "Built-in MLX default family; verify local server availability and model files.",
                  taskFit: ["fast summary", "routing", "low-risk chat", "offline fallback"],
                  estimatedDiskGB: 3,
                  estimatedMemoryGB: 6,
                  quantization: "4-bit MLX",
                  score: 76,
                  why: "Small, fast fallback that should fit more machines; not a primary coding brain.",
                  objective: objective)
    }

    private static func phiMiniOllama(memoryGB: Int, objective: String) -> LocalModelScoutCandidate {
        candidate(id: "phi-mini-ollama",
                  modelID: "phi3.5:latest",
                  provider: "ollama",
                  source: "Ollama registry; verify exact current tag and Microsoft license terms before pull.",
                  taskFit: ["tiny local assistant", "classification", "low-risk utility"],
                  estimatedDiskGB: 3,
                  estimatedMemoryGB: 6,
                  quantization: "Ollama default quantization for tag",
                  score: 70,
                  why: "Useful tiny fallback if the task values latency over coding depth.",
                  objective: objective)
    }

    private static func embeddingCompanion(memoryGB: Int, objective: String) -> LocalModelScoutCandidate {
        candidate(id: "nomic-embed-ollama",
                  modelID: "nomic-embed-text:latest",
                  provider: "ollama",
                  source: "Ollama registry; verify embedding endpoint compatibility before use.",
                  taskFit: ["retrieval", "memory index", "RAG", "semantic search"],
                  estimatedDiskGB: 1,
                  estimatedMemoryGB: 4,
                  quantization: "embedding model",
                  score: 78,
                  why: "Embedding companion for local memory/retrieval, not a chat model.",
                  objective: objective)
    }

    private static func candidate(id: String,
                                  modelID: String,
                                  provider: String,
                                  source: String,
                                  taskFit: [String],
                                  estimatedDiskGB: Int,
                                  estimatedMemoryGB: Int,
                                  quantization: String,
                                  score: Int,
                                  why: String,
                                  objective: String) -> LocalModelScoutCandidate {
        let safeSlug = slug(modelID)
        let localDir = ".kist/models/\(safeSlug)"
        let inspectTarget = provider == "mlx" ? "\(localDir)/tokenizer_config.json" : localDir
        let vetSpec = provider == "ollama" ? "ollama:\(modelID)" : "\(provider):\(modelID)"
        let installStep: String
        if provider == "ollama" {
            installStep = "Ollama pulls need separate registry provenance review; `/model vet \(vetSpec)` only verifies installed-local metadata."
        } else {
            installStep = "After `/model vet \(vetSpec)` writes a manifest-approved acquisition manifest, run `/model acquire <manifest.json>` before its pinned `hf download ... --revision <sha>` command."
        }
        return LocalModelScoutCandidate(
            id: id,
            modelID: modelID,
            provider: provider,
            source: source,
            taskFit: taskFit,
            estimatedDiskGB: estimatedDiskGB,
            estimatedMemoryGB: estimatedMemoryGB,
            quantization: quantization,
            score: score,
            why: why,
            licenseGate: "Open the model card and upstream base model license; reject if commercial/project use is unclear.",
            templateGate: "Run `kist --inspect-model \(inspectTarget)` or verify the provider stop profile before agent loops.",
            risks: [
                "Model id, license, quantization, and files can drift; verify before download.",
                "Small local models can stall tool loops; keep them in plan/low-risk roles until onboarding passes.",
                "Do not replace the default model until benchmark evidence beats the current baseline for this task family."
            ],
            onboardingSteps: [
                "Create a sandbox folder: `mkdir -p .kist/models`.",
                "Fetch live metadata and write the acquisition manifest: `/model vet \(vetSpec)`.",
                "Verify the manifest before download: `/model acquire <manifest.json>`.",
                installStep,
                "Inspect stops/templates: `kist --inspect-model \(inspectTarget)`.",
                "Onboard through the real loop: `kist --onboard \(provider):\(modelID) --onboard-doc \(inspectTarget)`.",
                "Keep rollback: leave the current default model pinned until the eval gate passes."
            ],
            evalPlan: [
                "Run `/bench \(objective.isEmpty ? "local model candidate task" : objective)` against the current default and candidate.",
                "Run `/eval \(objective.isEmpty ? "local model candidate task" : objective)` and require clean tool-loop behavior.",
                "Promote only after repeated wins are visible in `/learning`."
            ])
    }

    private static func adjustedForHardware(_ candidate: LocalModelScoutCandidate,
                                            memoryGB: Int) -> LocalModelScoutCandidate {
        var out = candidate
        if candidate.estimatedMemoryGB > memoryGB {
            out.score = max(10, out.score - 35)
            out.risks.insert("Estimated memory exceeds host memory; treat this as not installable without a larger machine.", at: 0)
        } else if candidate.estimatedMemoryGB > max(4, Int(Double(memoryGB) * 0.75)) {
            out.score = max(10, out.score - 12)
            out.risks.insert("Memory fit is tight; benchmark latency and swap pressure before any routing.", at: 0)
        }
        return out
    }

    private static func containsAny(_ text: String, _ needles: [String]) -> Bool {
        needles.contains { text.contains($0) }
    }

    private static func slug(_ value: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789-_")
        let lower = value.lowercased().replacingOccurrences(of: "/", with: "-")
        let filtered = lower.map { allowed.contains($0) ? $0 : "-" }
        return String(filtered).split(separator: "-").joined(separator: "-")
    }
}
