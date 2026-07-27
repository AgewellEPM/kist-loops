import SwiftUI

/// Sliding sidebar showing conversation history
struct LibrarySidebarView: View {
    @ObservedObject var conversationManager: ConversationManager
    @Binding var isShowing: Bool
    var onSelectConversation: (ChatConversation) -> Void

    @State private var searchText = ""
    @State private var editingConversation: ChatConversation?
    @State private var newTitle = ""
    @State private var conversationToDelete: ChatConversation?
    @State private var showDeleteConfirmation = false

    private var filteredConversations: [ChatConversation] {
        if searchText.isEmpty {
            return conversationManager.conversations
        }
        let query = searchText.lowercased()
        return conversationManager.conversations.filter { conversation in
            // Search in title
            if conversation.title.lowercased().contains(query) {
                return true
            }
            // Search in message content
            return conversation.messages.contains { message in
                message.content.lowercased().contains(query)
            }
        }
    }

    /// Returns whether this conversation matches by message content (not title)
    private func matchesInContent(_ conversation: ChatConversation) -> Bool {
        guard !searchText.isEmpty else { return false }
        let query = searchText.lowercased()
        if conversation.title.lowercased().contains(query) {
            return false // Matched by title, not content
        }
        return conversation.messages.contains { $0.content.lowercased().contains(query) }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Conversations")
                    .font(.headline)
                    .foregroundColor(.primary)

                Spacer()

                Button(action: {
                    _ = conversationManager.createNewConversation()
                }) {
                    Image(systemName: "plus.circle.fill")
                        .font(.title2)
                        .foregroundColor(.accentColor)
                }
                .buttonStyle(.plain)
                .help("New Conversation")

                Button(action: { isShowing = false }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding()
            .background(Color.secondary.opacity(0.1))

            // Search
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                TextField("Search titles & messages", text: $searchText)
                    .textFieldStyle(.plain)
                if !searchText.isEmpty {
                    Button(action: { searchText = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(8)
            .background(Color.secondary.opacity(0.1))
            .cornerRadius(8)
            .padding(.horizontal)
            .padding(.vertical, 8)

            // Search results count
            if !searchText.isEmpty {
                Text("\(filteredConversations.count) result\(filteredConversations.count == 1 ? "" : "s")")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .padding(.horizontal)
            }

            Divider()

            // Conversation List
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(filteredConversations) { conversation in
                        ConversationRow(
                            conversation: conversation,
                            isSelected: conversation.id == conversationManager.currentConversationId,
                            isEditing: editingConversation?.id == conversation.id,
                            editTitle: $newTitle,
                            onSelect: {
                                onSelectConversation(conversation)
                            },
                            onRename: {
                                editingConversation = conversation
                                newTitle = conversation.title
                            },
                            onSaveRename: {
                                if !newTitle.isEmpty {
                                    conversationManager.renameConversation(conversation, to: newTitle)
                                }
                                editingConversation = nil
                            },
                            onCancelRename: {
                                editingConversation = nil
                            },
                            onDelete: {
                                conversationToDelete = conversation
                                showDeleteConfirmation = true
                            }
                        )
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
            }

            Divider()

            // Context Memory Section
            contextMemorySection
        }
        .frame(width: 280)
        .background(Color.sidebarBackground)
        .confirmationDialog(
            "Delete Conversation?",
            isPresented: $showDeleteConfirmation,
            presenting: conversationToDelete
        ) { conversation in
            Button("Delete", role: .destructive) {
                conversationManager.deleteConversation(conversation)
                conversationToDelete = nil
            }
            Button("Cancel", role: .cancel) {
                conversationToDelete = nil
            }
        } message: { conversation in
            Text("This will permanently delete '\(conversation.title)'. This action cannot be undone.")
        }
    }

    private var contextMemorySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "brain")
                    .foregroundColor(.purple)
                Text("Memory")
                    .font(.caption.bold())
                Spacer()
            }
            .padding(.horizontal)
            .padding(.top, 8)

            if !conversationManager.contextMemory.activeContexts.isEmpty {
                ForEach(conversationManager.contextMemory.activeContexts) { context in
                    HStack(spacing: 6) {
                        Image(systemName: contextIcon(for: context.type))
                            .foregroundColor(.secondary)
                            .font(.caption)
                        Text(context.name)
                            .font(.caption)
                            .lineLimit(1)
                        Spacer()
                        Button(action: {
                            conversationManager.clearActiveContext(type: context.type)
                        }) {
                            Image(systemName: "xmark")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal)
                }
            } else {
                Text("No active context")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.horizontal)
            }

            Spacer(minLength: 8)
        }
        .frame(height: 100)
        .background(Color.secondary.opacity(0.05))
    }

    private func contextIcon(for type: ActiveContext.ContextType) -> String {
        switch type {
        case .application: return "app"
        case .document: return "doc"
        case .file: return "doc.text"
        case .website: return "globe"
        case .folder: return "folder"
        case .custom: return "star"
        }
    }
}

// MARK: - Conversation Row

struct ConversationRow: View {
    let conversation: ChatConversation
    let isSelected: Bool
    let isEditing: Bool
    @Binding var editTitle: String
    let onSelect: () -> Void
    let onRename: () -> Void
    let onSaveRename: () -> Void
    let onCancelRename: () -> Void
    let onDelete: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "bubble.left")
                .foregroundColor(isSelected ? .white : .secondary)
                .font(.system(size: 14))

            if isEditing {
                TextField("Title", text: $editTitle, onCommit: onSaveRename)
                    .textFieldStyle(.plain)
                    .onExitCommand(perform: onCancelRename)
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    Text(conversation.title)
                        .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                        .lineLimit(1)
                        .foregroundColor(isSelected ? .white : .primary)

                    Text(formatDate(conversation.updatedAt))
                        .font(.caption2)
                        .foregroundColor(isSelected ? .white.opacity(0.7) : .secondary)
                }
            }

            Spacer()

            if isHovered && !isEditing {
                HStack(spacing: 4) {
                    Button(action: onRename) {
                        Image(systemName: "pencil")
                            .font(.caption)
                    }
                    .buttonStyle(.plain)

                    Button(action: onDelete) {
                        Image(systemName: "trash")
                            .font(.caption)
                            .foregroundColor(.red)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isSelected ? Color.accentColor : (isHovered ? Color.secondary.opacity(0.15) : Color.clear))
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHover { hovering in
            isHovered = hovering
        }
        .contextMenu {
            Button("Rename", action: onRename)
            Divider()
            Button("Delete", role: .destructive, action: onDelete)
        }
    }

    private func formatDate(_ date: Date) -> String {
        let calendar = Calendar.current

        if calendar.isDateInToday(date) {
            return "Today"
        } else if calendar.isDateInYesterday(date) {
            return "Yesterday"
        } else {
            let formatter = DateFormatter()
            formatter.dateStyle = .short
            return formatter.string(from: date)
        }
    }
}

// MARK: - Color Extension

extension Color {
    static var sidebarBackground: Color {
        Color(nsColor: NSColor.windowBackgroundColor)
    }
}
