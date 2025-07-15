import Foundation

struct ConfigEncoder {
    
    func encode(_ input: [String: String]) -> String {
        // Group keys by section
        var sections: [String: [String: String]] = [:]
        for (fullKey, value) in input {
            let parts = fullKey.split(separator: ".")
            guard parts.count >= 2 else { continue }
            let section = parts.count == 3
            ? "\(parts[0]) \"\(parts[1])\""
            : String(parts[0])
            let key = parts.count == 3
            ? String(parts[2])
            : String(parts[1])
            sections[section, default: [:]][key] = value
        }
        // Write sections
        var lines: [String] = []
        for section in sections.keys.sorted() {
            lines.append("[\(section)]")
            for (key, value) in sections[section]!.sorted(by: { $0.key < $1.key }) {
                lines.append("    \(key) = \(value)")
            }
        }
        return lines.joined(separator: "\n")
    }
}

struct ConfigDecoder {

    func decode(_ input: String) -> [String: String] {
        var result: [String: String] = [:]
        var currentSection = ""

        let sectionRegex = try! NSRegularExpression(pattern: #"^\[(.+?)(?:\s+"(.+?)")?\]$"#)

        for line in input.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix(";") || trimmed.hasPrefix("#") {
                continue // skip comments and empty lines
            }
            if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") {
                if let match = sectionRegex.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)) {
                    let section = (trimmed as NSString).substring(with: match.range(at: 1))
                    if match.range(at: 2).location != NSNotFound {
                        let subsection = (trimmed as NSString).substring(with: match.range(at: 2))
                        currentSection = "\(section).\(subsection)"
                    } else {
                        currentSection = section
                    }
                }
            } else if let equalIndex = trimmed.firstIndex(of: "=") {
                let key = trimmed[..<equalIndex].trimmingCharacters(in: .whitespaces)
                let value = trimmed[trimmed.index(after: equalIndex)...].trimmingCharacters(in: .whitespaces)
                let dictKey = currentSection.isEmpty ? key : "\(currentSection).\(key)"
                result[dictKey] = value
            }
        }
        return result
    }
}
