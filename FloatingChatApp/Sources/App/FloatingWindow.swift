import AppKit
import SwiftUI

final class FloatingWindow: NSPanel {
    private var hostingView: NSHostingView<AnyView>?

    init<Content: View>(contentView: Content) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 600),
            styleMask: [.borderless, .nonactivatingPanel, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        configureWindow()
        setupContent(contentView)
    }

    private func configureWindow() {
        // Window behavior
        level = .floating
        isFloatingPanel = true
        hidesOnDeactivate = false
        isMovableByWindowBackground = true
        isOpaque = false
        backgroundColor = .clear

        // Visual appearance
        hasShadow = true
        titlebarAppearsTransparent = true
        titleVisibility = .hidden

        // Allow mouse events when not key window
        acceptsMouseMovedEvents = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        // Set minimum size
        minSize = NSSize(width: 320, height: 400)
        maxSize = NSSize(width: 800, height: 1200)

        // Center on screen
        if let screen = NSScreen.main {
            let screenRect = screen.visibleFrame
            let windowRect = frame
            let newOrigin = NSPoint(
                x: screenRect.maxX - windowRect.width - 20,
                y: screenRect.maxY - windowRect.height - 20
            )
            setFrameOrigin(newOrigin)
        }
    }

    private func setupContent<Content: View>(_ content: Content) {
        let wrappedContent = WindowContent(closeAction: { [weak self] in
            self?.close()
        }) {
            content
        }

        hostingView = NSHostingView(rootView: AnyView(wrappedContent))
        hostingView?.wantsLayer = true
        hostingView?.layer?.cornerRadius = 16
        hostingView?.layer?.masksToBounds = true
        contentView = hostingView
    }

    func show() {
        makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

// MARK: - Window Content Wrapper

struct WindowContent<Content: View>: View {
    let closeAction: () -> Void
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .background(WindowAccessor())
    }
}

struct WindowAccessor: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            view.window?.isOpaque = false
            view.window?.backgroundColor = .clear
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
