import Foundation

@MainActor
final class MLXWhisperServerManager: ObservableObject {
    static let shared = MLXWhisperServerManager()

    @Published var isServerRunning = false
    @Published var isStarting = false
    @Published var errorMessage: String?
    @Published var serverOutput: String = ""

    private var process: Process?
    private var outputPipe: Pipe?
    private var errorPipe: Pipe?
    private var healthTimer: Timer?
    private var scriptPath: String?

    private init() {}

    deinit {
        // Clean up process synchronously - safe because we're just terminating
        healthTimer?.invalidate()
        process?.terminate()
        if let script = scriptPath { try? FileManager.default.removeItem(atPath: script) }
    }

    func ensureRunning(serverURL: String, model: String = "small") async {
        if await checkHealth(url: serverURL) {
            isServerRunning = true
            return
        }
        await start(serverURL: serverURL, model: model)
    }

    func start(serverURL: String, model: String = "small") async {
        guard !isStarting else { return }
        isStarting = true
        errorMessage = nil
        serverOutput = ""

        let (host, port) = parseURL(serverURL)
        guard let py = findPython3() else {
            errorMessage = "python3 not found. Install via Homebrew or Xcode Command Line Tools."
            isStarting = false
            return
        }

        // Write script to temp path
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        let path = tmp.appendingPathComponent("mlx_whisper_server_\(UUID().uuidString).py").path
        do {
            try Self.serverScript.write(toFile: path, atomically: true, encoding: .utf8)
            self.scriptPath = path
        } catch {
            errorMessage = "Failed to write server script: \(error.localizedDescription)"
            isStarting = false
            return
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        proc.arguments = [py, path, "--host", host, "--port", String(port), "--model", model]
        var env = ProcessInfo.processInfo.environment
        env["PYTHONUNBUFFERED"] = "1"
        proc.environment = env

        let out = Pipe(); let err = Pipe()
        proc.standardOutput = out
        proc.standardError = err

        out.fileHandleForReading.readabilityHandler = { [weak self] handle in
            guard let self = self else { return }
            if let text = String(data: handle.availableData, encoding: .utf8), !text.isEmpty {
                Task { @MainActor in
                    self.serverOutput += text
                }
            }
        }
        err.fileHandleForReading.readabilityHandler = { [weak self] handle in
            guard let self = self else { return }
            if let text = String(data: handle.availableData, encoding: .utf8), !text.isEmpty {
                Task { @MainActor in
                    self.serverOutput += text
                }
            }
        }

        proc.terminationHandler = { [weak self] _ in
            Task { @MainActor in
                self?.isServerRunning = false
                self?.isStarting = false
            }
        }

        do {
            try proc.run()
            self.process = proc
            self.outputPipe = out
            self.errorPipe = err
        } catch {
            errorMessage = "Failed to start server: \(error.localizedDescription)"
            isStarting = false
            return
        }

        // Poll health
        let startTime = Date()
        while Date().timeIntervalSince(startTime) < 20 {
            if await checkHealth(url: serverURL) {
                isServerRunning = true
                isStarting = false
                startHealthTimer(url: serverURL)
                return
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }

        isStarting = false
        errorMessage = "MLX Whisper server did not become healthy in time."
    }

    func stop() {
        healthTimer?.invalidate(); healthTimer = nil
        process?.terminate()
        process = nil
        isServerRunning = false
        if let script = scriptPath { try? FileManager.default.removeItem(atPath: script) }
        scriptPath = nil
    }

    private func startHealthTimer(url: String) {
        healthTimer?.invalidate()
        healthTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                let ok = await self?.checkHealth(url: url) ?? false
                self?.isServerRunning = ok
            }
        }
    }

    private func parseURL(_ url: String) -> (String, Int) {
        if let u = URL(string: url), let host = u.host, let port = u.port {
            return (host, port)
        }
        return ("127.0.0.1", 8081)
    }

    private func checkHealth(url: String) async -> Bool {
        guard let u = URL(string: url + "/health") else { return false }
        do { let (_, resp) = try await URLSession.shared.data(from: u); return (resp as? HTTPURLResponse)?.statusCode == 200 } catch { return false }
    }

    private func findPython3() -> String? {
        let candidates = [
            "/usr/bin/python3",
            "/opt/homebrew/bin/python3",
            "/usr/local/bin/python3"
        ]
        for p in candidates where FileManager.default.isExecutableFile(atPath: p) { return p }
        return "python3" // Fallback to PATH
    }

    private static let serverScript = """
#!/usr/bin/env python3
import argparse
import io
import json
import os
import tempfile
from flask import Flask, request, jsonify

app = Flask(__name__)
ARGS = None

def transcribe_bytes(data: bytes, model_name: str):
    with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as f:
        f.write(data)
        path = f.name
    try:
        try:
            import importlib
            mw = importlib.import_module("mlx_whisper")
            if hasattr(mw, "load_model") and hasattr(mw, "transcribe"):
                model = mw.load_model(model_name)
                result = mw.transcribe(model, path)
                if isinstance(result, dict) and "text" in result:
                    return result["text"].strip()
                if hasattr(result, "text"):
                    return str(result.text).strip()
            import subprocess, sys
            cmd = [sys.executable, "-m", "mlx_whisper", "transcribe", "--model", model_name, path]
            out = subprocess.check_output(cmd, stderr=subprocess.STDOUT, text=True)
            return out.strip()
        except Exception:
            import whisper
            model = whisper.load_model(model_name)
            result = model.transcribe(path, fp16=False)
            return result.get("text", "").strip()
    finally:
        try: os.remove(path)
        except Exception: pass

@app.get("/health")
def health():
    return jsonify({"ok": True}), 200

@app.post("/transcribe")
def transcribe_endpoint():
    data = request.get_data()
    if not data:
        return jsonify({"error": "empty body"}), 400
    text = transcribe_bytes(data, ARGS.model)
    return jsonify({"text": text})

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=8081)
    parser.add_argument("--host", type=str, default="127.0.0.1")
    parser.add_argument("--model", type=str, default="small")
    global ARGS
    ARGS = parser.parse_args()
    app.run(host=ARGS.host, port=ARGS.port)

if __name__ == "__main__":
    main()
"""
}

