import Foundation

extension FileManager {

    /// Creates a directory if it doesn't already exist.
    func mkdir(_ url: URL) throws {
        guard !fileExists(atPath: url.path) else { return }
        let directoryURL = url.hasDirectoryPath ? url : url.deletingLastPathComponent()
        try createDirectory(at: directoryURL, withIntermediateDirectories: true)
    }

    /// Creates a file if it doesn't already exist, even if the given content is nil.
    func touch(_ url: URL, contents: String? = nil) throws {
        guard !fileExists(atPath: url.path) else { return }
        try mkdir(url)
        createFile(atPath: url.path, contents: contents?.data(using: .utf8))
    }
}

extension String {

    func trimmingSlashes() -> String {
        trimmingCharacters(in: .init(charactersIn: "/"))
    }
}

extension Date {

    var toISO8601_UTC: String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.formatOptions = [
            .withInternetDateTime,
            .withFractionalSeconds
        ]
        return formatter.string(from: self)
    }

    static func parseISO8601_UTC(_ string: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.formatOptions = [
            .withInternetDateTime,
            .withFractionalSeconds
        ]
        return formatter.date(from: string)
    }
}

extension Collection {

    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

infix operator /: MultiplicationPrecedence

func / (lhs: URL, rhs: String) -> URL {
    lhs.appending(path: rhs)
}
