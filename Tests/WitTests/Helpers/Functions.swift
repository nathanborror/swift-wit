import Foundation
import CryptoKit
@testable import Wit

func NewRepo() -> (String, RepoSession) {
    let ident = UUID().uuidString
    let privateKey = Curve25519.Signing.PrivateKey()
    let baseURL = URL.documentsDirectory.appending(path: ident)
    let repo = RepoSession(baseURL: baseURL, privateKey: privateKey)
    return (ident, repo)
}

func RemoveDirectory(_ path: String) {
    try? FileManager.default.removeItem(at: .documentsDirectory/path)
}

@discardableResult
func CommitFile(_ repo: RepoSession, path: String, content: String = UUID().uuidString, message: String? = nil) async throws -> String {
    try await repo.write(content, path: path)
    return try await repo.commit(message ?? "Added \(path)")
}
