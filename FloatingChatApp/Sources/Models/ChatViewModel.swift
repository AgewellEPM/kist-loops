import Foundation
import Combine
import AppKit

@MainActor
final class ChatViewModel: ObservableObject {
    @Published var messages: [ChatMessage] = []
    @Published var inputText: String = ""
    @Published var isLoading: Bool = false
    @Published var errorMessage: String?
    @Published var showError: Bool = false
    @Published var lastErrorWasRetryable: Bool = false
    @Published var lastErrorWasAuth: Bool = false

    // Store last user message for retry
    private var lastUserMessageContent: String?
    private var lastUserMessageImageData: Data?
    private var lastUserMessageImageMimeType: String?

    @Published var selectedProvider: any AIProvider
    @Published var availableProviders: [any AIProvider]

    // Image attachment for vision
    @Published var attachedImage: Data?
    @Published var attachedImageMimeType: String?

    private var streamTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()

    private let providerManager = ProviderManager.shared
    private let settingsManager = ModelSettingsManager.shared

    init() {
        self.selectedProvider = providerManager.currentProvider
        self.availableProviders = providerManager.availableProviders

        // Sync with provider manager
        providerManager.$currentProvider
            .receive(on: DispatchQueue.main)
            .sink { [weak self] provider in
                self?.selectedProvider = provider
            }
            .store(in: &cancellables)
    }

    var currentSettings: ModelSettings {
        settingsManager.globalSettings
    }

    func selectProvider(_ provider: any AIProvider) {
        providerManager.selectProvider(id: provider.id)
    }

    func sendMessage() {
        let trimmedInput = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedInput.isEmpty || attachedImage != nil else { return }

        // Store for potential retry
        lastUserMessageContent = trimmedInput
        lastUserMessageImageData = attachedImage
        lastUserMessageImageMimeType = attachedImageMimeType

        // Add user message with optional image
        let userMessage = ChatMessage.user(
            trimmedInput,
            imageData: attachedImage,
            imageMimeType: attachedImageMimeType
        )
        messages.append(userMessage)
        inputText = ""

        // Clear attached image after sending
        attachedImage = nil
        attachedImageMimeType = nil

        // Clear previous error state
        lastErrorWasRetryable = false
        lastErrorWasAuth = false

        // Create placeholder for assistant response
        let assistantMessage = ChatMessage.assistant("", isStreaming: true)
        messages.append(assistantMessage)

        isLoading = true
        errorMessage = nil

        let settings = currentSettings

        streamTask = Task {
            do {
                let shouldStream = settings.streamResponses && selectedProvider.supportsStreaming
                let stream = try await selectedProvider.sendMessage(
                    messages: messages.dropLast().map { $0 },  // Exclude the streaming placeholder
                    settings: settings,
                    stream: shouldStream
                )

                var fullResponse = ""

                for try await chunk in stream {
                    fullResponse += chunk

                    // Update the last message with streaming content
                    if let lastIndex = messages.indices.last {
                        messages[lastIndex].content = fullResponse
                    }
                }

                // Mark streaming complete
                if let lastIndex = messages.indices.last {
                    messages[lastIndex].isStreaming = false
                }

            } catch {
                // Remove the empty assistant message on error
                if let lastIndex = messages.indices.last,
                   messages[lastIndex].role == .assistant && messages[lastIndex].content.isEmpty {
                    messages.removeLast()
                }

                // Detect error type for retry/settings buttons
                if let providerError = error as? AIProviderError {
                    lastErrorWasRetryable = providerError.isRetryable
                    lastErrorWasAuth = providerError == .invalidAPIKey
                } else {
                    // Network errors are generally retryable
                    lastErrorWasRetryable = (error as NSError).domain == NSURLErrorDomain
                    lastErrorWasAuth = false
                }

                errorMessage = error.localizedDescription
                showError = true
            }

            isLoading = false
        }
    }

    func stopGeneration() {
        streamTask?.cancel()
        streamTask = nil
        isLoading = false

        // Mark current message as not streaming
        if let lastIndex = messages.indices.last,
           messages[lastIndex].isStreaming {
            messages[lastIndex].isStreaming = false
        }
    }

    func regenerateLastResponse() {
        guard messages.count >= 2 else { return }

        // Remove last assistant message
        if messages.last?.role == .assistant {
            messages.removeLast()
        }

        // Re-send with the same context
        if let lastUserMessage = messages.last(where: { $0.role == .user }) {
            inputText = lastUserMessage.content
            messages.removeLast()
            sendMessage()
        }
    }

    func retryLastMessage() {
        guard let content = lastUserMessageContent else { return }

        // Clear the error
        showError = false
        errorMessage = nil

        // Re-attach image if there was one
        if let imageData = lastUserMessageImageData {
            attachedImage = imageData
            attachedImageMimeType = lastUserMessageImageMimeType
        }

        // Set input and send
        inputText = content
        sendMessage()
    }

    func clearChat() {
        messages.removeAll()
        errorMessage = nil
        showError = false
        attachedImage = nil
        attachedImageMimeType = nil
        lastUserMessageContent = nil
        lastUserMessageImageData = nil
        lastUserMessageImageMimeType = nil
        lastErrorWasRetryable = false
        lastErrorWasAuth = false
    }

    func copyMessage(_ message: ChatMessage) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(message.content, forType: .string)
    }

    func attachImage(_ imageData: Data, mimeType: String = "image/png") {
        guard selectedProvider.supportsVision else {
            errorMessage = "Selected model doesn't support vision. Switch to a vision model."
            showError = true
            return
        }
        attachedImage = imageData
        attachedImageMimeType = mimeType
    }

    func removeAttachedImage() {
        attachedImage = nil
        attachedImageMimeType = nil
    }
}
