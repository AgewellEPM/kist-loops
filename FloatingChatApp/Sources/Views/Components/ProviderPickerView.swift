import SwiftUI

struct ProviderPickerView: View {
    let providers: [any AIProvider]
    let selectedProvider: any AIProvider
    let onSelect: (any AIProvider) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var expandedProviders: Set<String> = []
    @State private var refreshingProvider: String?

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Select AI Model")
                    .font(.headline)
                Spacer()
                Button("Done") {
                    dismiss()
                }
                .buttonStyle(.plain)
                .foregroundColor(.accentColor)
            }
            .padding()

            Divider()

            // Provider list
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(providers, id: \.id) { provider in
                        ProviderSection(
                            provider: provider,
                            isSelected: provider.id == selectedProvider.id,
                            isExpanded: expandedProviders.contains(provider.id),
                            isRefreshing: refreshingProvider == provider.id,
                            hasAPIKey: ProviderManager.shared.hasAPIKey(for: provider),
                            onSelectProvider: {
                                onSelect(provider)
                            },
                            onSelectModel: { model in
                                selectModel(model, for: provider)
                            },
                            onToggleExpand: {
                                toggleExpand(provider)
                            },
                            onRefresh: {
                                refreshModels(for: provider)
                            }
                        )
                    }
                }
                .padding()
            }
        }
        .frame(width: 340, height: 450)
        .background(Color.chatBackground)
        .onAppear {
            // Auto-expand selected provider
            expandedProviders.insert(selectedProvider.id)
        }
    }

    private func toggleExpand(_ provider: any AIProvider) {
        if expandedProviders.contains(provider.id) {
            expandedProviders.remove(provider.id)
        } else {
            expandedProviders.insert(provider.id)
        }
    }

    private func selectModel(_ model: AIModel, for provider: any AIProvider) {
        // Get mutable version from ProviderManager
        if let index = ProviderManager.shared.availableProviders.firstIndex(where: { $0.id == provider.id }) {
            var mutableProvider = ProviderManager.shared.availableProviders[index]
            mutableProvider.selectedModel = model
        }
        onSelect(provider)
    }

    private func refreshModels(for provider: any AIProvider) {
        refreshingProvider = provider.id
        Task {
            _ = await provider.refreshModels()
            await MainActor.run {
                refreshingProvider = nil
            }
        }
    }
}

// MARK: - Provider Section

struct ProviderSection: View {
    let provider: any AIProvider
    let isSelected: Bool
    let isExpanded: Bool
    let isRefreshing: Bool
    let hasAPIKey: Bool
    let onSelectProvider: () -> Void
    let onSelectModel: (AIModel) -> Void
    let onToggleExpand: () -> Void
    let onRefresh: () -> Void

    @State private var isHovering = false

    var body: some View {
        VStack(spacing: 0) {
            // Provider header
            Button(action: onToggleExpand) {
                HStack(spacing: 12) {
                    // Expand indicator
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.secondary)
                        .frame(width: 12)

                    // Icon
                    Image(systemName: provider.iconName)
                        .font(.system(size: 18))
                        .foregroundColor(isSelected ? .accentColor : .secondary)
                        .frame(width: 24)

                    // Provider info
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 6) {
                            Text(provider.name)
                                .font(.system(size: 14, weight: .medium))
                                .foregroundColor(.primary)

                            if provider.isLocal {
                                Text("Local")
                                    .font(.system(size: 9))
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 1)
                                    .background(Color.green.opacity(0.2))
                                    .foregroundColor(.green)
                                    .cornerRadius(3)
                            }
                        }

                        // Status
                        statusText
                    }

                    Spacer()

                    // Selection indicator
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.accentColor)
                            .font(.system(size: 16))
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(isSelected ? Color.accentColor.opacity(0.1) : (isHovering ? Color.secondary.opacity(0.08) : Color.clear))
                )
            }
            .buttonStyle(.plain)
            .onHover { hovering in
                isHovering = hovering
            }

            // Expanded model list
            if isExpanded {
                VStack(spacing: 2) {
                    ForEach(provider.availableModels) { model in
                        ModelRow(
                            model: model,
                            isSelected: provider.selectedModel?.id == model.id,
                            onSelect: { onSelectModel(model) }
                        )
                    }

                    // Refresh button for local providers
                    if provider.isLocal {
                        Button(action: onRefresh) {
                            HStack(spacing: 6) {
                                if isRefreshing {
                                    ProgressView()
                                        .scaleEffect(0.6)
                                        .frame(width: 14, height: 14)
                                } else {
                                    Image(systemName: "arrow.clockwise")
                                        .font(.system(size: 11))
                                }
                                Text("Refresh Models")
                                    .font(.system(size: 11))
                            }
                            .foregroundColor(.secondary)
                            .padding(.vertical, 6)
                        }
                        .buttonStyle(.plain)
                        .disabled(isRefreshing)
                    }
                }
                .padding(.leading, 44)
                .padding(.top, 4)
            }
        }
    }

    @ViewBuilder
    private var statusText: some View {
        if provider.requiresAPIKey && !hasAPIKey {
            Text("API key required")
                .font(.system(size: 11))
                .foregroundColor(.orange)
        } else if let model = provider.selectedModel {
            HStack(spacing: 4) {
                Text(model.displayName)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                if model.isVision {
                    Image(systemName: "eye")
                        .font(.system(size: 9))
                        .foregroundColor(.purple)
                }
            }
        } else {
            Text(provider.isLocal ? "Select a model" : "Ready")
                .font(.system(size: 11))
                .foregroundColor(provider.isLocal ? .orange : .green)
        }
    }
}

// MARK: - Model Row

struct ModelRow: View {
    let model: AIModel
    let isSelected: Bool
    let onSelect: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 8) {
                // Selection indicator
                Circle()
                    .fill(isSelected ? Color.accentColor : Color.clear)
                    .frame(width: 8, height: 8)
                    .overlay(
                        Circle()
                            .stroke(isSelected ? Color.accentColor : Color.secondary.opacity(0.3), lineWidth: 1)
                    )

                // Model name
                Text(model.displayName)
                    .font(.system(size: 12))
                    .foregroundColor(isSelected ? .primary : .secondary)
                    .lineLimit(1)

                // Vision badge
                if model.isVision {
                    Image(systemName: "eye.fill")
                        .font(.system(size: 9))
                        .foregroundColor(.purple)
                }

                Spacer()

                // Size if available
                if let size = model.size {
                    Text(size)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary.opacity(0.7))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.1))
                        .cornerRadius(4)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isHovering ? Color.secondary.opacity(0.08) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovering = hovering
        }
    }
}

