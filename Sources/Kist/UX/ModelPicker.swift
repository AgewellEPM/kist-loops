import Foundation
import AgentCore
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// The arrow-key model picker behind a bare `/model` (Claude-Code style): a live-filterable list you
/// navigate with ↑/↓, type to filter, Enter to pick, Esc to cancel. The navigation/filter logic is a pure
/// value type (`ModelPickerState`) so it's unit-tested without a terminal; `ModelPicker.run` is the thin
/// raw-mode shell that renders it and reads keys.
struct ModelPickerState: Equatable {
    struct Entry: Equatable {
        let providerId: String
        let model: String?
        let hasKey: Bool          // true ⇒ an API key is configured (renders green) · false ⇒ needs one (red)
        let detail: String?
        var label: String { providerId + (model.map { " · \($0)" } ?? "") + (detail.map { " · \($0)" } ?? "") }
        init(providerId: String, model: String?, hasKey: Bool = true, detail: String? = nil) {
            self.providerId = providerId; self.model = model; self.hasKey = hasKey
            self.detail = detail
        }
    }

    let all: [Entry]
    private(set) var filter: String = ""
    private(set) var cursor: Int = 0   // index into `filtered`

    init(all: [Entry], initialSelection: Int = 0) {
        self.all = all
        self.cursor = max(0, min(initialSelection, max(0, all.count - 1)))
    }

    /// Entries matching the current filter (case-insensitive substring on the label). Empty filter ⇒ all.
    var filtered: [Entry] {
        guard !filter.isEmpty else { return all }
        let needle = filter.lowercased()
        return all.filter { $0.label.lowercased().contains(needle) }
    }

    /// The currently-highlighted entry, or nil when the filter matches nothing.
    var current: Entry? {
        let f = filtered
        guard !f.isEmpty, cursor >= 0, cursor < f.count else { return nil }
        return f[cursor]
    }

    mutating func moveUp() {
        let n = filtered.count
        guard n > 0 else { return }
        cursor = (cursor - 1 + n) % n     // wrap
    }
    mutating func moveDown() {
        let n = filtered.count
        guard n > 0 else { return }
        cursor = (cursor + 1) % n          // wrap
    }
    mutating func type(_ ch: Character) {
        filter.append(ch)
        cursor = 0                          // new filter ⇒ back to the top match
    }
    mutating func backspace() {
        guard !filter.isEmpty else { return }
        filter.removeLast()
        cursor = 0
    }
}

enum ModelPicker {
    /// Build the picker entries from the REPL's catalog: every (provider, model) pair, plus a bare
    /// provider entry (its default model) so a provider with no listed models is still selectable.
    static func entries(providerModels: [String: [String]], providers: [String],
                        hasKey: (String) -> Bool = { _ in true }) -> [ModelPickerState.Entry] {
        var out: [ModelPickerState.Entry] = []
        var seen = Set<String>()
        func add(_ providerId: String, _ model: String?) {
            let key = providerId + "|" + (model ?? "")
            if seen.insert(key).inserted {
                out.append(.init(providerId: providerId, model: model, hasKey: hasKey(providerId)))
            }
        }
        for provider in providers.sorted() {
            let models = (providerModels[provider] ?? []).sorted()
            if models.isEmpty { add(provider, nil) } else { for m in models { add(provider, m) } }
        }
        // Any provider only present as a models-key (not in `providers`) still gets listed.
        for (provider, models) in providerModels where !providers.contains(provider) {
            for m in models.sorted() { add(provider, m) }
        }
        // Keyed providers (green, ready) float to the top; within a group, keep the stable order above.
        return out.enumerated()
            .sorted { ($0.element.hasKey ? 0 : 1, $0.offset) < ($1.element.hasKey ? 0 : 1, $1.offset) }
            .map { $0.element }
    }

    private static let maxRows = 10

    /// Run the interactive picker. Returns the chosen entry, or nil on cancel / not-a-TTY / empty list.
    static func run(entries: [ModelPickerState.Entry], current: ProviderBinding) -> ModelPickerState.Entry? {
        guard isatty(STDIN_FILENO) != 0, isatty(STDOUT_FILENO) != 0, !entries.isEmpty else { return nil }
        let initial = entries.firstIndex { $0.providerId == current.providerId && $0.model == current.model }
            ?? entries.firstIndex { $0.providerId == current.providerId }
            ?? 0
        var state = ModelPickerState(all: entries, initialSelection: initial)

        let raw = RawMode()
        raw.enable()
        var prevLines = 0
        func write(_ s: String) { FileHandle.standardOutput.write(Data(s.utf8)) }
        func draw() {
            let lines = renderLines(state)
            var out = ""
            if prevLines > 0 { out += "\u{001B}[\(prevLines)F" }   // up to the block start
            out += "\u{001B}[0J"                                    // clear from here down
            out += lines.joined(separator: "\n")
            write(out)
            prevLines = lines.count
        }
        func teardown() {
            if prevLines > 0 { write("\u{001B}[\(prevLines)F\u{001B}[0J") }   // erase the picker UI
            raw.disable()
        }

        draw()
        while true {
            let bytes = raw.readBytes(max: 64)
            if bytes.isEmpty { teardown(); return nil }   // EOF
            for key in KeyDecoder.decode(bytes) {
                switch key {
                case .up: state.moveUp()
                case .down: state.moveDown()
                case .enter:
                    let picked = state.current
                    teardown()
                    return picked
                case .escape:
                    teardown(); return nil
                case .backspace:
                    state.backspace()
                case .char(let c):
                    if c == "\u{03}" { teardown(); return nil }   // ctrl-C cancels
                    if c.isLetter || c.isNumber || c == "-" || c == "." || c == ":" || c == " " || c == "_" {
                        state.type(c)
                    }
                default:
                    break
                }
                draw()
            }
        }
    }

    private static func renderLines(_ state: ModelPickerState) -> [String] {
        var lines: [String] = []
        lines.append("\u{001B}[36;1mpick a model\u{001B}[0m \u{001B}[2m· ↑/↓ move · type to filter · enter select · esc cancel\u{001B}[0m")
        lines.append("\u{001B}[2m\u{001B}[32m●\u{001B}[0m\u{001B}[2m ready   \u{001B}[31m●\u{001B}[0m\u{001B}[2m needs a key — /model import <url> to add one\u{001B}[0m")
        let filterShown = state.filter.isEmpty ? "\u{001B}[2m(type to filter)\u{001B}[0m" : state.filter
        lines.append("\u{001B}[2m❯\u{001B}[0m \(filterShown)")
        let f = state.filtered
        if f.isEmpty {
            lines.append("  \u{001B}[31mno model matches '\(state.filter)'\u{001B}[0m")
            return lines
        }
        // Scroll a window of maxRows around the cursor so a long catalog stays on screen.
        let window = min(maxRows, f.count)
        var start = max(0, state.cursor - window / 2)
        start = min(start, max(0, f.count - window))
        let width = min(60, max(24, TerminalMediaRenderer.terminalColumns(default: 60)))
        for i in start..<(start + window) {
            lines.append(rowLine(f[i], selected: i == state.cursor, width: width))
        }
        if f.count > window {
            lines.append("\u{001B}[2m  … \(f.count) total\u{001B}[0m")
        }
        return lines
    }

    /// One row, colored by API-key status: green = ready, red = needs a key. The CURSOR row is a full-width
    /// grey selection bar (fzf/Claude-Code style) with the SAME green/red text — so a model's key status
    /// stays unmistakable even while it's highlighted. The bar (256-color bg) degrades to bold text on
    /// basic terminals, which is still legibly green/red.
    private static func rowLine(_ e: ModelPickerState.Entry, selected: Bool, width: Int) -> String {
        let fg = e.hasKey ? "32" : "31"                          // green vs red — decided from key status FIRST
        let text = (selected ? "❯ " : "  ") + e.label
        guard selected else { return "\u{001B}[\(fg)m\(text)\u{001B}[0m" }
        let pad = String(repeating: " ", count: max(0, width - text.count))
        return "\u{001B}[48;5;236;\(fg);1m\(text)\(pad)\u{001B}[0m"   // grey bar + bold green/red text
    }
}
