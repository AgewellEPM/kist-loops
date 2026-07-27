import Foundation
import SwiftUI
import AVFoundation
import Speech

@MainActor
final class VoiceInputManager: ObservableObject {
    static let shared = VoiceInputManager()

    @Published var isAuthorized: Bool = false
    @Published var isRecording: Bool = false
    @Published var partialText: String = ""
    @Published var lastFinalText: String = ""

    enum Engine: String { case apple, mlx }

    private var selectedEngine: Engine {
        let raw = UserDefaults.standard.string(forKey: "voice_engine") ?? Engine.apple.rawValue
        return Engine(rawValue: raw) ?? .apple
    }
    private var mlxServerURL: String {
        UserDefaults.standard.string(forKey: "mlx_whisper_url") ?? "http://localhost:8081"
    }

    private let recognizer: SFSpeechRecognizer?
    private let audioEngine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?

    // Recording for MLX (file-based)
    private var audioFile: AVAudioFile?
    private var convertFormat: AVAudioFormat?
    private var converter: AVAudioConverter?
    private var fileURL: URL?

    private init() {
        self.recognizer = SFSpeechRecognizer(locale: Locale.current)
    }

    // MARK: - Permissions

    func requestAuthorization() async -> Bool {
        // Always need mic permission
        let micGranted: Bool = await withCheckedContinuation { cont in
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                cont.resume(returning: granted)
            }
        }

        var speechOK = true
        if selectedEngine == .apple {
            let speechStatus: SFSpeechRecognizerAuthorizationStatus = await withCheckedContinuation { cont in
                SFSpeechRecognizer.requestAuthorization { status in
                    cont.resume(returning: status)
                }
            }
            speechOK = (speechStatus == .authorized)
        }

        let ok = micGranted && speechOK
        isAuthorized = ok
        return ok
    }

    // MARK: - Recording

    func start() async throws {
        guard !isRecording else { return }
        partialText = ""
        lastFinalText = ""
        let engine = selectedEngine

        switch engine {
        case .apple:
            try startApple()
        case .mlx:
            // Ensure server is running if user enabled autostart
            let autostart = UserDefaults.standard.bool(forKey: "mlx_whisper_autostart")
            if autostart {
                await MLXWhisperServerManager.shared.ensureRunning(serverURL: mlxServerURL, model: UserDefaults.standard.string(forKey: "mlx_whisper_model") ?? "small")
            }
            try startMLXRecording()
            startMLXStreamingIfEnabled()
        }
        isRecording = true
    }

    func stop() {
        guard isRecording else { return }
        let engine = selectedEngine

        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)

        switch engine {
        case .apple:
            request?.endAudio()
            recognitionTask?.cancel()
            recognitionTask = nil
            request = nil
            isRecording = false
        case .mlx:
            // Close file then transcribe
            audioFile = nil
            isRecording = false
            stopMLXStreaming()
            if let url = fileURL {
                Task { @MainActor in
                    let text = await self.transcribeViaMLX(url: url)
                    self.partialText = text
                    self.lastFinalText = text
                }
            }
        }
    }

    // MARK: - MLX Streaming (pseudo)

    private var streamingTimer: Timer?
    private var isStreamingInFlight = false
    private var lastStreamedSize: UInt64 = 0

    private var mlxStreamingEnabled: Bool {
        UserDefaults.standard.bool(forKey: "mlx_whisper_streaming")
    }

    private var mlxStreamInterval: TimeInterval {
        let v = UserDefaults.standard.double(forKey: "mlx_whisper_stream_interval")
        return v > 0 ? v : 1.5
    }

    private func startMLXStreamingIfEnabled() {
        guard mlxStreamingEnabled else { return }
        streamingTimer?.invalidate()
        lastStreamedSize = 0
        streamingTimer = Timer.scheduledTimer(withTimeInterval: mlxStreamInterval, repeats: true) { [weak self] _ in
            guard let self = self, self.isRecording, let url = self.fileURL else { return }
            if self.isStreamingInFlight { return }
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? UInt64) ?? 0
            if size <= self.lastStreamedSize || size < 8000 { return } // wait for some audio
            self.isStreamingInFlight = true
            Task { @MainActor in
                let txt = await self.transcribeViaMLX(url: url)
                if !txt.isEmpty { self.partialText = txt }
                self.lastStreamedSize = size
                self.isStreamingInFlight = false
            }
        }
    }

    private func stopMLXStreaming() {
        streamingTimer?.invalidate()
        streamingTimer = nil
        isStreamingInFlight = false
        lastStreamedSize = 0
    }

    // MARK: - Apple Speech

    private func startApple() throws {
        guard recognizer?.isAvailable ?? false else {
            throw NSError(domain: "VoiceInput", code: 1, userInfo: [NSLocalizedDescriptionKey: "Speech recognizer not available. Check network settings."])
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        self.request = request

        let inputNode = audioEngine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)
        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { [weak self] buffer, _ in
            self?.request?.append(buffer)
        }

        audioEngine.prepare()
        try audioEngine.start()

        recognitionTask = recognizer?.recognitionTask(with: request) { [weak self] result, error in
            guard let self = self else { return }
            if let result = result {
                self.partialText = result.bestTranscription.formattedString
                if result.isFinal {
                    self.lastFinalText = self.partialText
                }
            }

            if error != nil {
                self.stop()
            }
        }
    }

    // MARK: - MLX Recording (file-based)

    private func startMLXRecording() throws {
        let inputNode = audioEngine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        // Target mono 16kHz, 16-bit interleaved WAV-compatible format
        guard let targetFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true) else {
            throw NSError(domain: "VoiceInput", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to create target audio format"])
        }
        self.convertFormat = targetFormat
        self.converter = AVAudioConverter(from: inputFormat, to: targetFormat)

        // File path
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        let url = tmp.appendingPathComponent("voice_\(UUID().uuidString).wav")
        self.fileURL = url

        // WAV file settings
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: targetFormat.sampleRate,
            AVNumberOfChannelsKey: targetFormat.channelCount,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false
        ]
        self.audioFile = try AVAudioFile(forWriting: url, settings: settings)

        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            guard let self = self, let converter = self.converter, let audioFile = self.audioFile else { return }

            let outputBufferCapacity = AVAudioFrameCount(self.convertFormat?.sampleRate ?? 16_000) // 1 sec buffer max
            guard let outBuffer = AVAudioPCMBuffer(pcmFormat: self.convertFormat!, frameCapacity: outputBufferCapacity) else { return }

            buffer.frameLength = buffer.frameCapacity

            let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
                outStatus.pointee = .haveData
                return buffer
            }

            do {
                try converter.convert(to: outBuffer, error: nil, withInputFrom: inputBlock)
                if outBuffer.frameLength > 0 {
                    try audioFile.write(from: outBuffer)
                }
            } catch {
                // Ignore write errors while recording
            }
        }

        audioEngine.prepare()
        try audioEngine.start()
    }

    // MARK: - MLX Transcription via HTTP server

    private func transcribeViaMLX(url: URL) async -> String {
        guard let endpoint = URL(string: mlxServerURL + "/transcribe") else { return "" }
        guard let data = try? Data(contentsOf: url) else { return "" }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.setValue(url.lastPathComponent, forHTTPHeaderField: "X-Filename")
        request.httpBody = data

        do {
            let (respData, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return "" }
            if let json = try? JSONSerialization.jsonObject(with: respData) as? [String: Any],
               let text = json["text"] as? String {
                return text
            } else if let txt = String(data: respData, encoding: .utf8) {
                return txt
            }
        } catch {
            return ""
        }
        return ""
    }
}
