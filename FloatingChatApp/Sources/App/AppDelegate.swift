import AppKit
import SwiftUI
import os

private let logger = Logger(subsystem: "com.floatingchat.app", category: "AppDelegate")

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var floatingWindow: FloatingWindow?
    private var statusItem: NSStatusItem?
    private var chatViewModel: ChatViewModel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        chatViewModel = ChatViewModel()
        setupStatusBarItem()
        setupGlobalHotkey()
        showFloatingWindow()
    }

    private func setupGlobalHotkey() {
        // Register Cmd+Shift+Space to summon the chat window
        HotkeyService.shared.onHotkeyPressed = { [weak self] in
            self?.toggleFloatingWindow()
            // Bring app to front
            NSApp.activate(ignoringOtherApps: true)
        }
        HotkeyService.shared.registerGlobalHotkey()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    private func setupStatusBarItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "bubble.left.fill", accessibilityDescription: "Chat")
            button.action = #selector(toggleFloatingWindow)
            button.target = self
        }

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Show Chat", action: #selector(showFloatingWindow), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Settings...", action: #selector(openSettings), keyEquivalent: ","))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        statusItem?.menu = menu
    }

    @objc private func toggleFloatingWindow() {
        if let window = floatingWindow, window.isVisible {
            window.close()
        } else {
            showFloatingWindow()
        }
    }

    @objc func showFloatingWindow() {
        if floatingWindow == nil, let viewModel = chatViewModel {
            let contentView = ChatView(viewModel: viewModel)
            floatingWindow = FloatingWindow(contentView: contentView)
        }
        floatingWindow?.show()
    }

    @objc private func openSettings() {
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }
}
