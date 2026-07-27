import SwiftUI
import AppKit

/// A sheet view for selecting a project folder when entering agent mode
struct ProjectFolderPickerView: View {
    let onSelect: (String) -> Void
    let onCancel: () -> Void

    @State private var selectedPath: String = ""
    @State private var recentProjects: [String] = []

    var body: some View {
        VStack(spacing: 20) {
            // Header
            VStack(spacing: 8) {
                Image(systemName: "folder.badge.gearshape")
                    .font(.system(size: 40))
                    .foregroundColor(.orange)

                Text("Select Project Folder")
                    .font(.title2)
                    .fontWeight(.semibold)

                Text("Choose the root folder of your Xcode project or Swift package. The agent will work within this directory.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }

            Divider()

            // Current selection display
            if !selectedPath.isEmpty {
                HStack {
                    Image(systemName: "folder.fill")
                        .foregroundColor(.blue)
                    Text(selectedPath)
                        .font(.system(size: 12, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                }
                .padding(10)
                .background(Color.blue.opacity(0.1))
                .cornerRadius(8)
            }

            // Recent projects (if any)
            if !recentProjects.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Recent Projects")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    ForEach(recentProjects, id: \.self) { path in
                        Button(action: {
                            selectedPath = path
                        }) {
                            HStack {
                                Image(systemName: "clock.arrow.circlepath")
                                    .font(.system(size: 12))
                                    .foregroundColor(.secondary)
                                Text(URL(fileURLWithPath: path).lastPathComponent)
                                    .font(.system(size: 12))
                                Spacer()
                                Text(shortenPath(path))
                                    .font(.system(size: 10))
                                    .foregroundColor(.secondary)
                            }
                            .padding(8)
                            .background(selectedPath == path ? Color.accentColor.opacity(0.1) : Color.clear)
                            .cornerRadius(6)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            Spacer()

            // Action buttons
            HStack(spacing: 12) {
                Button("Cancel") {
                    onCancel()
                }
                .buttonStyle(.bordered)
                .keyboardShortcut(.escape, modifiers: [])

                Spacer()

                Button(action: browseForFolder) {
                    Label("Browse...", systemImage: "folder")
                }
                .buttonStyle(.bordered)

                Button("Select") {
                    guard !selectedPath.isEmpty else { return }
                    saveToRecentProjects(selectedPath)
                    onSelect(selectedPath)
                }
                .buttonStyle(.borderedProminent)
                .disabled(selectedPath.isEmpty)
                .keyboardShortcut(.return, modifiers: [])
            }
        }
        .padding(24)
        .frame(width: 500, height: 400)
        .onAppear {
            loadRecentProjects()
        }
    }

    // MARK: - Actions

    private func browseForFolder() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = false
        panel.message = "Select your project folder"
        panel.prompt = "Select"

        // Start in a reasonable location
        if let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            panel.directoryURL = documentsURL
        }

        if panel.runModal() == .OK, let url = panel.url {
            selectedPath = url.path
        }
    }

    // MARK: - Persistence

    private let recentProjectsKey = "recent_agent_projects"
    private let maxRecentProjects = 5

    private func loadRecentProjects() {
        recentProjects = UserDefaults.standard.stringArray(forKey: recentProjectsKey) ?? []
        // Validate paths still exist
        recentProjects = recentProjects.filter { FileManager.default.fileExists(atPath: $0) }
    }

    private func saveToRecentProjects(_ path: String) {
        var recent = UserDefaults.standard.stringArray(forKey: recentProjectsKey) ?? []
        // Remove if already exists
        recent.removeAll { $0 == path }
        // Add to front
        recent.insert(path, at: 0)
        // Limit count
        if recent.count > maxRecentProjects {
            recent = Array(recent.prefix(maxRecentProjects))
        }
        UserDefaults.standard.set(recent, forKey: recentProjectsKey)
    }

    // MARK: - Helpers

    private func shortenPath(_ path: String) -> String {
        let components = path.components(separatedBy: "/")
        if components.count > 3 {
            return ".../" + components.suffix(2).joined(separator: "/")
        }
        return path
    }
}

#Preview {
    ProjectFolderPickerView(
        onSelect: { path in print("Selected: \(path)") },
        onCancel: { print("Cancelled") }
    )
}
