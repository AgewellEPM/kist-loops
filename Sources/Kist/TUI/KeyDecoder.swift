import Foundation

/// A decoded keypress from raw-mode stdin.
enum TerminalKey: Equatable {
    case char(Character)
    case enter
    case backspace
    case tab
    case backTab          // shift+tab (ESC [ Z) — cycles the permission mode, Claude-Code-style
    case left, right, up, down
    case home, end, delete
    case ctrlC, ctrlD, ctrlL, ctrlU, ctrlV, ctrlW
    case escape
}

/// Decodes a buffer of raw bytes into keypresses. Pure (bytes in → keys out) so the control-byte and
/// escape-sequence handling is unit-tested without a terminal. Handles UTF-8 text runs, control keys,
/// and the common CSI cursor/edit sequences (`ESC [ A/B/C/D/H/F`, `ESC [ 3~`, …).
enum KeyDecoder {
    static func decode(_ bytes: [UInt8]) -> [TerminalKey] {
        var keys: [TerminalKey] = []
        var i = 0
        var textRun: [UInt8] = []

        func flushText() {
            guard !textRun.isEmpty else { return }
            for ch in String(decoding: textRun, as: UTF8.self) { keys.append(.char(ch)) }
            textRun.removeAll(keepingCapacity: true)
        }

        while i < bytes.count {
            let b = bytes[i]
            switch b {
            case 0x0D, 0x0A: flushText(); keys.append(.enter); i += 1
            case 0x7F, 0x08: flushText(); keys.append(.backspace); i += 1
            case 0x09:       flushText(); keys.append(.tab); i += 1
            case 0x03:       flushText(); keys.append(.ctrlC); i += 1
            case 0x04:       flushText(); keys.append(.ctrlD); i += 1
            case 0x0C:       flushText(); keys.append(.ctrlL); i += 1
            case 0x15:       flushText(); keys.append(.ctrlU); i += 1
            case 0x16:       flushText(); keys.append(.ctrlV); i += 1
            case 0x17:       flushText(); keys.append(.ctrlW); i += 1
            case 0x1B:
                flushText()
                let (key, consumed) = decodeEscape(bytes, from: i)
                keys.append(key); i += consumed
            case 0x00...0x1F:
                // Other control bytes we don't map — skip (don't inject as text).
                flushText(); i += 1
            default:
                textRun.append(b); i += 1
            }
        }
        flushText()
        return keys
    }

    /// Decode an escape sequence starting at `start` (bytes[start] == 0x1B). Returns the key + how many
    /// bytes it consumed (≥1). A lone ESC (nothing or non-`[` after) is `.escape`, consuming just it.
    private static func decodeEscape(_ bytes: [UInt8], from start: Int) -> (TerminalKey, Int) {
        guard start + 1 < bytes.count, bytes[start + 1] == 0x5B else { return (.escape, 1) }   // need ESC [
        // CSI: scan the final byte (a letter or '~').
        var j = start + 2
        var params: [UInt8] = []
        while j < bytes.count {
            let c = bytes[j]
            if (c >= 0x41 && c <= 0x7E) {     // final byte
                let consumed = j - start + 1
                switch c {
                case 0x41: return (.up, consumed)
                case 0x42: return (.down, consumed)
                case 0x43: return (.right, consumed)
                case 0x44: return (.left, consumed)
                case 0x48: return (.home, consumed)
                case 0x46: return (.end, consumed)
                case 0x5A: return (.backTab, consumed)   // ESC [ Z — shift+tab
                case 0x7E:                    // ESC [ <n> ~
                    switch String(decoding: params, as: UTF8.self) {
                    case "3": return (.delete, consumed)
                    case "1", "7": return (.home, consumed)
                    case "4", "8": return (.end, consumed)
                    default: return (.escape, consumed)
                    }
                default: return (.escape, consumed)
                }
            }
            params.append(c); j += 1
        }
        return (.escape, bytes.count - start)   // incomplete sequence — consume the rest
    }
}
