import Foundation

struct CSVDecoder {
    let delimiter: Character

    init(delimiter: Character = ",") {
        self.delimiter = delimiter
    }

    func decode(_ text: String) -> [[String]] {
        // Normalize line endings
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        var rows: [[String]] = []
        var row: [String] = []
        var field = ""

        var inQuotes = false
        let chars = Array(normalized)
        var i = 0

        while i < chars.count {
            let c = chars[i]

            if c == "\"" {
                if inQuotes,
                   i + 1 < chars.count,
                   chars[i + 1] == "\"" {
                    // Escaped quote ("")
                    field.append("\"")
                    i += 1
                } else {
                    // Entering or leaving quoted field
                    inQuotes.toggle()
                }
            } else if c == delimiter && !inQuotes {
                // End of field
                row.append(field)
                field.removeAll(keepingCapacity: true)
            } else if c == "\n" && !inQuotes {
                // End of record
                row.append(field)
                rows.append(row)
                row.removeAll(keepingCapacity: true)
                field.removeAll(keepingCapacity: true)
            } else {
                field.append(c)
            }

            i += 1
        }

        // Flush last field/row if there is any content
        if !field.isEmpty || !row.isEmpty {
            row.append(field)
            rows.append(row)
        }

        return rows
    }
}
