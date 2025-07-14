import Foundation

extension FileManager {

    func mkdir(_ url: URL) throws {
        guard !fileExists(atPath: url.path) else { return }
        let directoryURL = url.hasDirectoryPath ? url : url.deletingLastPathComponent()
        try createDirectory(at: directoryURL, withIntermediateDirectories: true)
    }

    func touch(_ url: URL) throws {
        guard !fileExists(atPath: url.path) else { return }
        try mkdir(url)
        createFile(atPath: url.path, contents: nil)
    }
}

extension String {

    func trimmingSlashes() -> String {
        trimmingCharacters(in: .init(charactersIn: "/"))
    }
}

infix operator /: MultiplicationPrecedence

func / (lhs: URL, rhs: String) -> URL {
    lhs.appending(path: rhs)
}
