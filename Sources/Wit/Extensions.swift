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

    public var toRFC1123: String {
        let formatter = Date.RFC1123Formatter
        return formatter.string(from: self)
    }

    public static func fromRFC1123(_ string: String) -> Date? {
        let formatter = RFC1123Formatter
        return formatter.date(from: string)
    }

    public static let RFC1123Formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: -8 * 3600)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        return formatter
    }()
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
