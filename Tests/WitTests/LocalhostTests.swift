import Foundation
import CryptoKit
import Testing
@testable import Wit

@Suite("Localhost Tests")
struct LocalhostTests {

    @Test("Push")
    func push() async throws {
        let userID = UUID().uuidString
        let privateKey = Curve25519.Signing.PrivateKey()
        let publicKey = privateKey.publicKey.rawRepresentation.base64EncodedString()

        let baseURL = URL.documentsDirectory.appending(path: userID)
        defer { try? FileManager.default.removeItem(at: baseURL) }

        // 1. Local initial commit
        let client = try Client(baseURL)
        let dir = baseURL.appending(path: "Documents")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        try "This is some foo".write(to: dir.appending(path: "foo.txt"), atomically: true, encoding: .utf8)
        try "This is some bar".write(to: dir.appending(path: "bar.txt"), atomically: true, encoding: .utf8)

        let initialCommitHash = try client.commit(
            message: "Initial structure",
            author: "Test User <test@example.com>"
        )
        let initialStatus = try client.status(commitHash: initialCommitHash)
        #expect(initialStatus.hasChanges == false)

        // 2. Remote work: register new user and push commit
        let remote = LocalRemote(baseURL: URL(string: "http://localhost:8080/\(userID)")!)
        let registerURL = URL(string: "http://localhost:8080/register")!
        let registerData = """
            {"id": "\(userID)", "publicKey": "\(publicKey)"}
            """.data(using: .utf8)!
        let _ = try await remote.put(url: registerURL, data: registerData, mimetype: "application/json", etag: nil, privateKey: privateKey)

        do {
            try await client.push(remote: remote, privateKey: privateKey)
        } catch {
            print(error)
        }

        // Unregister user
        let unregisterURL = URL(string: "http://localhost:8080/\(userID)/unregister")!
        let _ = try await remote.put(url: unregisterURL, data: Data(), mimetype: nil, etag: nil, privateKey: privateKey)
    }
}
