import Foundation

/// A minimal human readable configuration file format. There can be sections with keyed values or just a list of values. Sections can be prefixed with a
/// namespace. Here is an example:
///
///     [core]
///         version = 0.1
///     [user]
///         name = Nathan Borror
///     [remote:origin]
///         url = http://localhost:8080
///     [remote:github]
///         url = http://github.com/nathanborror/swift-wit
///     [favorites]
///         foo.md
///         bar.md
///
public struct Config: Sendable {
    public var sections: [String: Section]

    public enum Section: Sendable {
        case dictionary([String: String])
        case array([String])
    }

    public subscript(section section: String) -> Section? {
        sections[section]
    }

    public subscript(list section: String) -> [String]? {
        guard case .array(let items) = sections[section] else {
            return nil
        }
        return items
    }

    public subscript(dict section: String) -> [String: String]? {
        guard case .dictionary(let dict) = sections[section] else {
            return nil
        }
        return dict
    }

    public subscript(prefix prefix: String) -> Config {
        var sections = Dictionary(uniqueKeysWithValues: sections.filter { $0.key.hasPrefix(prefix) })
        sections = sections.reduce(into: [:]) {
            let key = $1.key.trimmingPrefix(prefix).trimmingPrefix(":")
            return $0[String(key)] = $1.value
        }
        return .init(sections: sections)
    }

    public subscript(key: String) -> String? {
        let parts = key.split(separator: ".", maxSplits: 1).map(String.init)
        guard parts.count == 2 else {
            if let section = sections[key] {
                return ConfigEncoder().encode(section: section).joined(separator: "\n")
            }
            return nil
        }
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
        guard var dict = self[dict: section] else { return }
        dict.removeValue(forKey: key)
        if dict.isEmpty {
            sections.removeValue(forKey: section)
        } else {
            sections[section] = .dictionary(dict)
        }
    }
}

public struct ConfigEncoder {

    public init() {}

    public func encode(_ input: [String: Config.Section]) -> String {
        var lines: [String] = []
        for key in input.keys.sorted() {
            lines.append("[\(key)]")
            let values = encode(section: input[key]!)
            lines += values.map { "    \($0)" }
        }
        return lines.joined(separator: "\n")
    }

    public func encode(section: Config.Section) -> [String] {
        switch section {
        case .dictionary(let dict):
            return dict
                .sorted { $0.key < $1.key }
                .compactMap {
                    if !$0.value.isEmpty {
                        return "\($0.key) = \($0.value)"
                    }
                    return nil
                }
        case .array(let items):
            return items
        }
    }
}

public struct ConfigDecoder {

    public init() {}

    // TODO: Review generated code
    public func decode(_ input: String) -> Config {
        var sections: [String: Config.Section] = [:]
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
