import Foundation

extension FileManager {

    func createDirectoryIfNeeded(_ url: URL) throws {
        if !FileManager.default.fileExists(atPath: url.path) {
            let directoryURL = url.hasDirectoryPath ? url : url.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        }
    }

    func createFileIfNeeded(_ url: URL) throws {
        if !FileManager.default.fileExists(atPath: url.path) {
            try createDirectoryIfNeeded(url)
            try "".write(to: url, atomically: true, encoding: .utf8)
        }
    }
}
