import Foundation
@testable import Wit

func NewRepo() -> (String, Repo) {
    let workingPath = UUID().uuidString
    let repo = Repo(url: .documentsDirectory/workingPath)
    return (workingPath, repo)
}

func RemoveDirectory(_ path: String) {
    try? FileManager.default.removeItem(at: .documentsDirectory/path)
}

@discardableResult
func CommitFile(_ repo: Repo, path: String, content: String = UUID().uuidString, message: String? = nil) async throws -> String {
    try await repo.write(content, path: path)
    return try await repo.commit(message ?? "Added \(path)")
}
