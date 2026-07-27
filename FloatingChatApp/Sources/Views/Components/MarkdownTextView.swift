import SwiftUI

struct MarkdownTextView: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(parseMarkdown(text).enumerated()), id: \.offset) { _, element in
                MarkdownElementView(element: element)
            }
        }
    }

    private func parseMarkdown(_ text: String) -> [MarkdownElement] {
        var elements: [MarkdownElement] = []
        let lines = text.components(separatedBy: "\n")
        var inCodeBlock = false
        var codeBlockContent = ""
        var codeBlockLanguage = ""

        for line in lines {
            // Code block handling
            if line.hasPrefix("```") {
                if inCodeBlock {
                    elements.append(.codeBlock(codeBlockContent.trimmingCharacters(in: .newlines), codeBlockLanguage))
                    codeBlockContent = ""
                    codeBlockLanguage = ""
                    inCodeBlock = false
                } else {
                    inCodeBlock = true
                    codeBlockLanguage = String(line.dropFirst(3))
                }
                continue
            }

            if inCodeBlock {
                codeBlockContent += (codeBlockContent.isEmpty ? "" : "\n") + line
                continue
            }

            // Headings
            if line.hasPrefix("### ") {
                elements.append(.heading(3, String(line.dropFirst(4))))
            } else if line.hasPrefix("## ") {
                elements.append(.heading(2, String(line.dropFirst(3))))
            } else if line.hasPrefix("# ") {
                elements.append(.heading(1, String(line.dropFirst(2))))
            }
            // Bullet points
            else if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("• ") {
                elements.append(.bulletPoint(String(line.dropFirst(2))))
            }
            // Numbered lists
            else if let match = line.range(of: #"^\d+\.\s"#, options: .regularExpression) {
                let numberStr = line[line.startIndex..<line.index(before: match.upperBound)]
                let number = Int(numberStr.trimmingCharacters(in: .whitespaces).dropLast()) ?? 1
                let content = String(line[match.upperBound...])
                elements.append(.numberedPoint(number, content))
            }
            // Regular text with inline formatting
            else if !line.isEmpty {
                elements.append(.text(line))
            }
        }

        // Handle unclosed code block
        if inCodeBlock && !codeBlockContent.isEmpty {
            elements.append(.codeBlock(codeBlockContent, codeBlockLanguage))
        }

        return elements
    }
}

struct MarkdownElementView: View {
    let element: MarkdownElement

    var body: some View {
        switch element {
        case .text(let content):
            Text(content)
                .font(.body)

        case .bold(let content):
            Text(content)
                .fontWeight(.bold)

        case .italic(let content):
            Text(content)
                .italic()

        case .code(let content):
            Text(content)
                .font(.system(.body, design: .monospaced))
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .background(Color.codeBackground)
                .clipShape(RoundedRectangle(cornerRadius: 4))

        case .codeBlock(let content, _):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(content)
                    .font(.system(.caption, design: .monospaced))
                    .padding(12)
            }
            .background(Color.codeBackground)
            .clipShape(RoundedRectangle(cornerRadius: 8))

        case .bulletPoint(let content):
            HStack(alignment: .top, spacing: 8) {
                Text("•")
                    .foregroundColor(.secondary)
                Text(content)
            }

        case .numberedPoint(let number, let content):
            HStack(alignment: .top, spacing: 8) {
                Text("\(number).")
                    .foregroundColor(.secondary)
                    .frame(width: 20, alignment: .trailing)
                Text(content)
            }

        case .heading(let level, let content):
            Text(content)
                .font(headingFont(level: level))
                .fontWeight(.bold)
                .padding(.top, level == 1 ? 8 : 4)

        case .link(let title, _):
            Text(title)
                .foregroundColor(.accentColor)
                .underline()
        }
    }

    private func headingFont(level: Int) -> Font {
        switch level {
        case 1: return .title2
        case 2: return .title3
        case 3: return .headline
        default: return .subheadline
        }
    }
}

enum MarkdownElement {
    case text(String)
    case bold(String)
    case italic(String)
    case code(String)
    case codeBlock(String, String) // content, language
    case bulletPoint(String)
    case numberedPoint(Int, String)
    case heading(Int, String) // level, content
    case link(String, String) // title, url
}
