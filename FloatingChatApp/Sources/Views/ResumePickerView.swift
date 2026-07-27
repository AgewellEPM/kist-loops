import SwiftUI

// MARK: - Unified resumable-run row

/// One resumable run, unified across the single-agent runtime and the
/// multi-agent orchestration engine.
struct ResumableRun: Identifiable, Equatable {
    enum Kind: String { case single, orchestration }

    let id: String
    let kind: Kind
    let title: String
    let detail: String
    let updatedAt: Date
}

// MARK: - View model (testable core)

/// Loads resumable runs from both stores and routes resume/discard to the right
/// engine. The load/filter/sort logic is unit-testable with injected stores.
@MainActor
final class ResumePickerViewModel: ObservableObject {
    @Published private(set) var runs: [ResumableRun] = []
    @Published var lastError: String?

    /// Which run kinds this picker may show. A picker presented from a view
    /// bound to one engine must only offer runs that engine can surface —
    /// otherwise a resumed run executes invisibly (Codex HIGH).
    private let allowedKinds: Set<ResumableRun.Kind>
    private let checkpointStore: CheckpointStore
    private let orchestrationStore: OrchestrationCheckpointStore

    init(
        allowedKinds: Set<ResumableRun.Kind> = [.single, .orchestration],
        checkpointStore: CheckpointStore = .shared,
        orchestrationStore: OrchestrationCheckpointStore = .shared
    ) {
        self.allowedKinds = allowedKinds
        self.checkpointStore = checkpointStore
        self.orchestrationStore = orchestrationStore
    }

    /// Rebuild the list (newest first). Only modes that can resume SAFELY are
    /// shown — parallel/collaborative orchestration is excluded because
    /// resuming them would duplicate side effects.
    func reload() {
        var items: [ResumableRun] = []

        if allowedKinds.contains(.single) {
            for checkpoint in checkpointStore.resumable() {
                items.append(ResumableRun(
                    id: checkpoint.id,
                    kind: .single,
                    title: checkpoint.title.isEmpty ? "(untitled run)" : checkpoint.title,
                    detail: "Single agent · \(checkpoint.status.rawValue) · iteration \(checkpoint.iterationCount)/\(checkpoint.maxIterations)",
                    updatedAt: checkpoint.updatedAt
                ))
            }
        }

        if allowedKinds.contains(.orchestration) {
            for checkpoint in orchestrationStore.resumable()
            where checkpoint.mode == .sequential || checkpoint.mode == .debate {
                items.append(ResumableRun(
                    id: checkpoint.id,
                    kind: .orchestration,
                    title: checkpoint.title.isEmpty ? "(untitled team run)" : checkpoint.title,
                    detail: "\(checkpoint.mode.rawValue.capitalized) team · \(checkpoint.phase.rawValue)",
                    updatedAt: checkpoint.updatedAt
                ))
            }
        }

        runs = items.sorted { $0.updatedAt > $1.updatedAt }
    }

    func discard(_ run: ResumableRun) {
        do {
            switch run.kind {
            case .single: try checkpointStore.delete(id: run.id)
            case .orchestration: try orchestrationStore.delete(id: run.id)
            }
            lastError = nil
        } catch {
            lastError = "Couldn't discard run: \(error.localizedDescription)"
        }
        reload()
    }

    /// Resume the run on its owning engine. Returns whether resume started.
    @discardableResult
    func resume(_ run: ResumableRun) async -> Bool {
        switch run.kind {
        case .single:
            return await UnifiedAgentRuntime.shared.resume(checkpointId: run.id).isSuccess
        case .orchestration:
            return await AgentLoopEngine.shared.resumeOrchestration(checkpointId: run.id)
        }
    }
}

// MARK: - View

/// A sheet that lets a human pick a resumable run and resume or discard it.
struct ResumePickerView: View {
    @StateObject private var viewModel: ResumePickerViewModel
    let onClose: () -> Void

    private let darkBg = Color(red: 0.10, green: 0.10, blue: 0.12)

    /// Defaults to orchestration-only: this picker is presented from the team
    /// chat (bound to AgentLoopEngine), and single-agent runs resume in a
    /// different runtime that this view does not render.
    init(allowedKinds: Set<ResumableRun.Kind> = [.orchestration], onClose: @escaping () -> Void) {
        _viewModel = StateObject(wrappedValue: ResumePickerViewModel(allowedKinds: allowedKinds))
        self.onClose = onClose
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().background(Color.white.opacity(0.1))

            if let error = viewModel.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
            }

            if viewModel.runs.isEmpty {
                emptyState
            } else {
                List {
                    ForEach(viewModel.runs) { run in
                        runRow(run)
                    }
                }
                .listStyle(.plain)
            }
        }
        .frame(minWidth: 460, minHeight: 360)
        .background(darkBg)
        .onAppear { viewModel.reload() }
    }

    private var header: some View {
        HStack {
            Image(systemName: "clock.arrow.circlepath")
            Text("Resume a run").font(.headline)
            Spacer()
            Button("Close", action: onClose).buttonStyle(.plain)
        }
        .padding(16)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "tray").font(.largeTitle).foregroundColor(.secondary)
            Text("No resumable runs").foregroundColor(.secondary)
            Text("Interrupted runs that can be safely continued will appear here.")
                .font(.caption).foregroundColor(.secondary).multilineTextAlignment(.center)
            Spacer()
        }
        .padding()
    }

    private func runRow(_ run: ResumableRun) -> some View {
        HStack(spacing: 12) {
            Image(systemName: run.kind == .single ? "person.fill" : "person.3.fill")
                .foregroundColor(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(run.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                Text(run.detail).font(.caption).foregroundColor(.secondary).lineLimit(1)
            }
            Spacer()
            Button("Resume") {
                let run = run
                onClose()
                Task { await viewModel.resume(run) }
            }
            .buttonStyle(.borderedProminent)
            Button(role: .destructive) {
                viewModel.discard(run)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.plain)
            .help("Discard this run")
        }
        .padding(.vertical, 4)
    }
}
