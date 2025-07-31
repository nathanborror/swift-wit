import Foundation

public enum Section: Sendable {
    case dictionary([String: String])
    case array([String])
}

public struct Config: Sendable {
    public var sections: [String: Section]

    public subscript(section section: String) -> Section? {
        sections[section]
    }

    // TODO: Review generated code
    public subscript(key: String) -> String? {
        let parts = key.split(separator: ".", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        guard case let .dictionary(dict) = sections[parts[0]] else { return nil }
        return dict[parts[1]]
    }

    public init(sections: [String: Section] = [:]) {
        self.sections = sections
    }

    public mutating func remove(section: String) {
        sections.removeValue(forKey: section)
    }

    public mutating func remove(section: String, key: String) {
        guard case var .dictionary(dict) = sections[section] else {
            return
        }
        dict.removeValue(forKey: key)
        if dict.isEmpty {
            sections.removeValue(forKey: section)
        } else {
            sections[section] = .dictionary(dict)
        }
    }
}

struct ConfigEncoder {

    // TODO: Review generated code
    func encode(_ input: [String: Section]) -> String {
        var lines: [String] = []
        for section in input.keys.sorted() {
            // Convert back from "section:label" to [section "label"] format
            let headerString = formatSectionHeader(section)
            lines.append("[\(headerString)]")
            switch input[section]! {
            case .dictionary(let dict):
                for (key, value) in dict.sorted(by: { $0.key < $1.key }) {
                    if !value.isEmpty {
                        // Quote value if it contains spaces
                        let quotedValue = value.contains(" ") ? "\"\(value)\"" : value
                        lines.append("    \(key) = \(quotedValue)")
                    }
                }
            case .array(let array):
                for value in array {
                    lines.append("    \(value)")
                }
            }
        }
        return lines.joined(separator: "\n")
    }

    // TODO: Review generated code
    private func formatSectionHeader(_ sectionKey: String) -> String {
        // Convert "section:label" back to section "label" format
        let parts = sectionKey.split(separator: ":", maxSplits: 1).map(String.init)
        if parts.count == 2 {
            return "\(parts[0]) \"\(parts[1])\""
        }
        return sectionKey
    }
}

struct ConfigDecoder {

    // TODO: Review generated code
    func decode(_ input: String) -> Config {
        var sections: [String: Section] = [:]
        var currentSection: String?
        var currentValues: [String] = []
        var currentDict: [String: String] = [:]

        for line in input.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix(";") || trimmed.hasPrefix("#") {
                continue
            }
            if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") {
                // Save previous section before moving on
                if let section = currentSection {
                    if !currentDict.isEmpty {
                        sections[section] = .dictionary(currentDict)
                    } else if !currentValues.isEmpty {
                        sections[section] = .array(currentValues)
                    }
                }
                // Parse section header - handle both [section] and [section "label"]
                let sectionContent = String(trimmed.dropFirst().dropLast())
                currentSection = parseSectionHeader(sectionContent)
                currentValues = []
                currentDict = [:]
            } else if let equalIndex = trimmed.firstIndex(of: "=") {
                let key = trimmed[..<equalIndex].trimmingCharacters(in: .whitespaces)
                let value = trimmed[trimmed.index(after: equalIndex)...].trimmingCharacters(in: .whitespaces)
                // Remove quotes if present
                let unquotedValue = unquoteValue(value)
                currentDict[key] = unquotedValue
            } else if !trimmed.isEmpty {
                currentValues.append(trimmed)
            }
        }
        // Don't forget the last section
        if let section = currentSection {
            if !currentDict.isEmpty {
                sections[section] = .dictionary(currentDict)
            } else if !currentValues.isEmpty {
                sections[section] = .array(currentValues)
            }
        }

        return Config(sections: sections)
    }

    // TODO: Review generated code
    private func parseSectionHeader(_ header: String) -> String {
        // Handle section headers like: remote "local" or just: core
        let trimmed = header.trimmingCharacters(in: .whitespaces)

        // Check if there's a quoted label
        if let firstQuote = trimmed.firstIndex(of: "\""),
           let lastQuote = trimmed.lastIndex(of: "\""),
           firstQuote < lastQuote {
            let beforeQuote = trimmed[..<firstQuote].trimmingCharacters(in: .whitespaces)
            let label = trimmed[trimmed.index(after: firstQuote)..<lastQuote]
            // Use colon separator instead of preserving quotes
            return "\(beforeQuote):\(label)"
        }

        return trimmed
    }

    // TODO: Review generated code
    private func unquoteValue(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("\"") && trimmed.hasSuffix("\"") && trimmed.count >= 2 {
            return String(trimmed.dropFirst().dropLast())
        }
        return trimmed
    }
}
