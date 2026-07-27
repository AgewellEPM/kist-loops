import Foundation
import Combine

/// Manages the MLX LM Server for local inference on Apple Silicon
/// Automatically starts/stops the server and manages model downloads
@MainActor
final class MLXServerManager: ObservableObject {
    static let shared = MLXServerManager()

    // MARK: - Published State

    @Published var isServerRunning = false
    @Published var isStarting = false
    @Published var currentModel: String?
    @Published var serverPort: Int = 8080
    @Published var errorMessage: String?
    @Published var serverOutput: String = ""

    // MARK: - Private State

    // Using nonisolated(unsafe) for cleanup access from deinit
    nonisolated(unsafe) private var serverProcess: Process?
    private var outputPipe: Pipe?
    private var errorPipe: Pipe?
    private var healthCheckTimer: Timer?

    private let baseURL: String = {
        UserDefaults.standard.string(forKey: "mlx_base_url") ?? "http://localhost:8080"
    }()

    private init() {
        // Check if server is already running on startup
        Task {
            await checkServerHealth()
        }
    }

    nonisolated func cleanup() {
        // Stop server process directly without MainActor - safe due to nonisolated(unsafe)
        serverProcess?.terminate()
    }

    // MARK: - Server Control

    /// Start the MLX server with the specified model
    func startServer(model: String = "mlx-community/Llama-3.2-3B-Instruct-4bit") async -> Bool {
        guard !isServerRunning && !isStarting else {
            return isServerRunning
        }

        isStarting = true
        errorMessage = nil
        serverOutput = ""
        currentModel = model

        // Find the mlx_lm.server executable
        guard let serverPath = findMLXServer() else {
            errorMessage = "MLX LM not found. Install with: pip install mlx-lm"
            isStarting = false
            return false
        }

        // Create the process
        let process = Process()
        process.executableURL = URL(fileURLWithPath: serverPath)
        process.arguments = [
            "--model", model,
            "--port", String(serverPort)
        ]

        // Set up pipes for output
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        // Handle output
        outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if let output = String(data: data, encoding: .utf8), !output.isEmpty {
                Task { @MainActor in
                    self?.serverOutput += output
                    // Check for server ready message
                    if output.contains("Uvicorn running") || output.contains("Started server") {
                        self?.isServerRunning = true
                        self?.isStarting = false
                    }
                }
            }
        }

        errorPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if let output = String(data: data, encoding: .utf8), !output.isEmpty {
                Task { @MainActor in
                    self?.serverOutput += output
                    // MLX outputs progress to stderr
                    if output.contains("Uvicorn running") || output.contains("Started server") || output.contains("Application startup complete") {
                        self?.isServerRunning = true
                        self?.isStarting = false
                    }
                }
            }
        }

        // Handle termination
        process.terminationHandler = { [weak self] _ in
            Task { @MainActor in
                self?.isServerRunning = false
                self?.isStarting = false
                self?.serverProcess = nil
            }
        }

        do {
            try process.run()
            self.serverProcess = process
            self.outputPipe = outputPipe
            self.errorPipe = errorPipe

            // Start health check polling
            startHealthCheckTimer()

            // Wait for server to be ready (with timeout)
            let startTime = Date()
            while !isServerRunning && Date().timeIntervalSince(startTime) < 60 {
                try await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds
                await checkServerHealth()
            }

            if !isServerRunning {
                errorMessage = "Server startup timed out. Check if model is downloading..."
            }

            isStarting = false
            return isServerRunning

        } catch {
            errorMessage = "Failed to start server: \(error.localizedDescription)"
            isStarting = false
            return false
        }
    }

    /// Stop the MLX server
    func stopServer() {
        healthCheckTimer?.invalidate()
        healthCheckTimer = nil

        if let process = serverProcess, process.isRunning {
            process.terminate()
        }

        serverProcess = nil
        outputPipe = nil
        errorPipe = nil
        isServerRunning = false
        isStarting = false
    }

    /// Restart the server with a different model
    func switchModel(_ model: String) async -> Bool {
        stopServer()
        try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 second
        return await startServer(model: model)
    }

    // MARK: - Health Check

    func checkServerHealth() async {
        guard let url = URL(string: "\(baseURL)/v1/models") else { return }

        do {
            let (_, response) = try await URLSession.shared.data(from: url)
            let isHealthy = (response as? HTTPURLResponse)?.statusCode == 200
            isServerRunning = isHealthy
        } catch {
            isServerRunning = false
        }
    }

    private func startHealthCheckTimer() {
        healthCheckTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.checkServerHealth()
            }
        }
    }

    // MARK: - MLX Installation Detection

    /// Find the mlx_lm.server executable
    private func findMLXServer() -> String? {
        let possiblePaths = [
            // Homebrew Python
            "/opt/homebrew/bin/mlx_lm.server",
            "/usr/local/bin/mlx_lm.server",
            // User Python
            "\(NSHomeDirectory())/.local/bin/mlx_lm.server",
            "\(NSHomeDirectory())/Library/Python/3.11/bin/mlx_lm.server",
            "\(NSHomeDirectory())/Library/Python/3.12/bin/mlx_lm.server",
            // Conda/Miniforge
            "\(NSHomeDirectory())/miniforge3/bin/mlx_lm.server",
            "\(NSHomeDirectory())/miniconda3/bin/mlx_lm.server",
            // pyenv
            "\(NSHomeDirectory())/.pyenv/shims/mlx_lm.server"
        ]

        for path in possiblePaths {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }

        // Try using `which` command
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = ["mlx_lm.server"]

        let pipe = Pipe()
        process.standardOutput = pipe

        do {
            try process.run()
            process.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !path.isEmpty {
                return path
            }
        } catch {}

        return nil
    }

    /// Check if MLX LM is installed
    func isMLXInstalled() -> Bool {
        return findMLXServer() != nil
    }

    /// Get available MLX models (cached list + downloaded)
    func getAvailableModels() -> [String] {
        return [
            "mlx-community/Llama-3.2-3B-Instruct-4bit",
            "mlx-community/Llama-3.2-1B-Instruct-4bit",
            "mlx-community/Mistral-7B-Instruct-v0.3-4bit",
            "mlx-community/gemma-2-9b-it-4bit",
            "mlx-community/Qwen2.5-7B-Instruct-4bit",
            "mlx-community/Qwen2.5-3B-Instruct-4bit",
            "mlx-community/Phi-3.5-mini-instruct-4bit",
            "mlx-community/DeepSeek-Coder-V2-Lite-Instruct-4bit",
            "mlx-community/CodeLlama-7b-Instruct-hf-4bit",
            "mlx-community/llava-1.5-7b-4bit",
            "mlx-community/Qwen2-VL-7B-Instruct-4bit"
        ]
    }

    /// Get recommended model for coding tasks
    func getRecommendedCodingModel() -> String {
        return "mlx-community/Qwen2.5-7B-Instruct-4bit"
    }
}
