import Foundation

public enum Section: Sendable {
    case dictionary([String: String])
    case array([String])
}

public struct Config: Sendable {
    public var sections: [String: Section] = [:]

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
}

struct ConfigEncoder {

    // TODO: Review generated code
    func encode(_ input: [String: Section]) -> String {
        var lines: [String] = []
        for section in input.keys.sorted() {
            lines.append("[\(section)]")
            switch input[section]! {
            case .dictionary(let dict):
                for (key, value) in dict.sorted(by: { $0.key < $1.key }) {
                    if !value.isEmpty {
                        lines.append("    \(key) = \(value)")
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
                // Start new section
                currentSection = String(trimmed.dropFirst().dropLast())
                currentValues = []
                currentDict = [:]
            } else if let equalIndex = trimmed.firstIndex(of: "=") {
                let key = trimmed[..<equalIndex].trimmingCharacters(in: .whitespaces)
                let value = trimmed[trimmed.index(after: equalIndex)...].trimmingCharacters(in: .whitespaces)
                currentDict[key] = value
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
}
