import Foundation
import OSLog

private let logger = Logger(subsystem: "RemoteHTTP", category: "Wit")

public actor RemoteDisk: Remote {

    let baseURL: URL

    private var cache: [String: Data]

    init(baseURL: URL) {
        self.baseURL =  baseURL
        self.cache = [:]
    }

    public func exists(path: String) async throws -> Bool {
        let url = baseURL/path
        return FileManager.default.fileExists(atPath: url.path)
    }

    public func get(path: String) async throws -> Data {
        if let cached = cache[path] {
            return cached
        }
        let url = baseURL/path
        let data = try Data(contentsOf: url)
        cache[path] = data
        return data
    }

    public func put(path: String, data: Data, mimetype: String?, privateKey: PrivateKey?) async throws {
        let url = baseURL/path
        try FileManager.default.mkdir(url)
        try data.write(to: url, options: .atomic)
        cache[path] = data
    }

    public func delete(path: String, privateKey: PrivateKey?) async throws {
        let url = baseURL/path
        try? FileManager.default.removeItem(at: url)
        cache.removeValue(forKey: path)
    }

    public func list(path: String, ignores: [String]) async throws -> [String: URL] {
        let url = baseURL/path
        let shouldIgnore: (String, [String]) -> Bool = { path, ignores in
            for ignore in ignores {
                if path.hasPrefix(ignore) {
                    return true
                }
            }
            return false
        }
        return await Task.detached(priority: .userInitiated) {
            var out: [String: URL] = [:]
            let enumerator = FileManager.default.enumerator(
                at: url,
                includingPropertiesForKeys: [.isRegularFileKey],
            )
            while let fileURL = enumerator?.nextObject() as? URL {
                let relativePath = fileURL.path.replacingOccurrences(of: url.path + "/", with: "")
                guard !shouldIgnore(relativePath, ignores) else { continue }
                out[relativePath] = fileURL
            }
            return out
        }.value
    }
}
