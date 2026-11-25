import SwiftUI

struct MarkdownMessage: View {
    let text: String
    let enabled: Bool

    var body: some View {
        if enabled {
            VStack(alignment: .leading, spacing: 7) {
                ForEach(Array(MarkdownBlock.parse(text).enumerated()), id: \.offset) { _, block in
                    switch block {
                    case .paragraph(let value): inline(value)
                    case .heading(let level, let value):
                        inline(value).font(level == 1 ? .title3.bold() : .headline).accessibilityAddTraits(.isHeader)
                    case .item(let marker, let value):
                        HStack(alignment: .firstTextBaseline, spacing: 5) { Text(verbatim: marker).foregroundStyle(.secondary); inline(value) }
                    case .quote(let value):
                        HStack(spacing: 7) { Capsule().fill(.tint).frame(width: 2); inline(value).foregroundStyle(.secondary) }.fixedSize(horizontal: false, vertical: true)
                    case .code(let value):
                        Text(verbatim: value).font(.system(.footnote, design: .monospaced)).padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading).background(.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                    case .divider: Divider()
                    case .table(let header, let rows):
                        ScrollView(.horizontal) {
                            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 5) {
                                GridRow { ForEach(header.indices, id: \.self) { inline(header[$0]).bold() } }
                                Divider()
                                ForEach(rows.indices, id: \.self) { i in
                                    GridRow { ForEach(rows[i].indices, id: \.self) { inline(rows[i][$0]) } }
                                }
                            }.font(.footnote).padding(.vertical, 3)
                        }
                    }
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        } else { Text(verbatim: text).frame(maxWidth: .infinity, alignment: .leading) }
    }

    private func inline(_ value: String) -> Text {
        let styled = try? AttributedString(markdown: value, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
        return Text(styled ?? AttributedString(value))
    }
}

private enum MarkdownBlock {
    case paragraph(String), heading(Int, String), item(String, String), quote(String), code(String), divider
    case table([String], [[String]])

    static func parse(_ source: String) -> [Self] {
        let lines = source.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var blocks: [Self] = [], paragraph: [String] = []
        func flush() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: "\n"))); paragraph.removeAll() }
        }
        func cells(_ line: String) -> [String] {
            line.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "|"))
                .components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
        }
        var index = 0
        while index < lines.count {
            let raw = lines[index], line = raw.trimmingCharacters(in: .whitespaces)
            index += 1
            let heading = line.prefix { $0 == "#" }, number = line.prefix(while: \.isNumber)
            if line.isEmpty { flush() }
            else if line.hasPrefix("```") || line.hasPrefix("~~~") {
                flush()
                let fence = line.prefix { $0 == line.first }
                var code: [String] = []
                while index < lines.count && !lines[index].trimmingCharacters(in: .whitespaces).hasPrefix(fence) {
                    code.append(lines[index]); index += 1
                }
                index += 1; blocks.append(.code(code.joined(separator: "\n")))
            } else if line.contains("|"), index < lines.count, lines[index].contains("|"),
                      cells(lines[index]).allSatisfy({ $0.range(of: #"^:?-{3,}:?$"#, options: .regularExpression) != nil }) {
                flush(); index += 1
                var rows: [[String]] = []
                while index < lines.count && lines[index].contains("|") { rows.append(cells(lines[index])); index += 1 }
                blocks.append(.table(cells(line), rows))
            } else if (1...6).contains(heading.count), line.dropFirst(heading.count).first == " " {
                flush(); blocks.append(.heading(heading.count, String(line.dropFirst(heading.count + 1))))
            } else if line.range(of: #"^([-*_])(?:\s*\1){2,}$"#, options: .regularExpression) != nil {
                flush(); blocks.append(.divider)
            } else if line.hasPrefix(">") {
                flush(); blocks.append(.quote(line.dropFirst().trimmingCharacters(in: .whitespaces)))
            } else if ["- ", "* ", "+ "].contains(String(line.prefix(2))) {
                flush(); blocks.append(.item("•", String(line.dropFirst(2))))
            } else if !number.isEmpty, line.dropFirst(number.count).hasPrefix(". ") {
                flush(); blocks.append(.item(number + ".", String(line.dropFirst(number.count + 2))))
            } else { paragraph.append(raw) }
        }
        flush(); return blocks
    }
}
