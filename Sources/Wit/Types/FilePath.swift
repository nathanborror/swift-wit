import Foundation

public typealias FilePath = String

extension FilePath {

    public var ext: String? {
        let ext = URL(fileURLWithPath: self).pathExtension
        return ext.isEmpty ? nil : ext
    }
    
    public func deletingLastPath() -> FilePath {
        let url = URL(fileURLWithPath: self)
        let dir = url.deletingLastPathComponent()
        let path = dir.relativePath
        guard path != "." else { return "" }
        return .init(path)
    }

    public func lastPathComponent() -> String {
        let url = URL(fileURLWithPath: self)
        return url.lastPathComponent
    }
}
