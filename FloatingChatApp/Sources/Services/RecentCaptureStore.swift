import Foundation

@MainActor
final class RecentCaptureStore: ObservableObject {
    static let shared = RecentCaptureStore()

    @Published var lastScreenshotPath: String?
    @Published var lastVideoPath: String?
    @Published var lastVideoMP4Path: String?
    @Published var lastFramePaths: [String] = []
    @Published var lastTranscriptPath: String?
    @Published var nextAutoAttachPath: String?

    private init() {}

    func setLastCapture(screenshot: String?, video: String? = nil, frames: [String] = [], mp4: String? = nil, transcript: String? = nil) {
        self.lastScreenshotPath = screenshot
        self.lastVideoPath = video
        self.lastVideoMP4Path = mp4
        self.lastFramePaths = frames
        self.lastTranscriptPath = transcript
    }
}
