import Foundation
import CryptoKit
import Testing
@testable import Wit

let isServerRunning = true

@Suite("Remote Tests", .enabled(if: isServerRunning))
final class RemoteTests {
    let privateKey: Remote.PrivateKey
    let identity: String
    let remote: Remote

    let clientA_workingFolder: String
    let clientA: RepoSession

    let clientB_workingFolder: String
    let clientB: RepoSession

    init() async throws {
        self.privateKey = Remote.PrivateKey()
        self.identity = UUID().uuidString

        self.clientA_workingFolder = "A-\(identity)"
        self.clientB_workingFolder = "B-\(identity)"

        let clientA_baseURL = URL.documentsDirectory.appending(path: clientA_workingFolder)
        let clientB_baseURL = URL.documentsDirectory.appending(path: clientB_workingFolder)

        self.clientA = RepoSession(baseURL: clientA_baseURL, privateKey: privateKey)
        try await clientA.initialize()

        let config = """
            Date: \(Date.now.toRFC1123)
            Content-Type: text/ini
            
            address = \(identity)@local
            publicKey = \(privateKey.publicKey.rawRepresentation.base64EncodedString())
            """
        try await clientA.write(config, path: clientA.configPath)

        self.remote = RemoteHTTP(baseURL: .init(string: "http://localhost:8080/home/\(identity)")!)

        // Register with remote HTTP server
        let registerRemote = RemoteHTTP(baseURL: .init(string: "http://localhost:8080")!)
        let configData = try await clientA.read(clientA.configPath)
        try await registerRemote.put(path: "register", data: configData, directoryHint: .notDirectory, privateKey: nil)

        self.clientB = RepoSession(baseURL: clientB_baseURL, privateKey: privateKey)
        try await self.clientB.initialize()
    }

    deinit { teardown() }

    func teardown() {
        try? FileManager.default.removeItem(at: .documentsDirectory/clientA_workingFolder)
        try? FileManager.default.removeItem(at: .documentsDirectory/clientB_workingFolder)
        let privateKey = privateKey
        let remote = RemoteHTTP(baseURL: .init(string: "http://localhost:8080/\(identity)")!)
        Task { try await remote.delete(path: "unregister", privateKey: privateKey) }
    }

    @Test("Push")
    func push() async throws {
        try await clientA.write("This is some foo", path: "foo.txt")
        try await clientA.write("This is some bar", path: "bar.txt")
        try await clientA.commit("Initial commit")
        try await clientA.push(remote)

        let logCheck1 = try await clientA.logs()
        #expect(logCheck1.count == 1)

        try await clientA.write("This is more foo", path: "foo.txt")
        try await clientA.commit("Second commit")
        try await clientA.push(remote)

        let logCheck2 = try await clientA.logs()
        #expect(logCheck2.count == 2)
    }

    @Test("Rebase")
    func rebase() async throws {

        // ClientA: First commit
        try await clientA.write("This is some foo", path: "foo.txt")
        try await clientA.commit("First commit")
        try await clientA.push(remote)

        try await clientA.write("This is some bar", path: "bar.txt")
        try await clientA.commit("Second commit")
        try await clientA.push(remote)

        try await clientA.write("This is some baz", path: "baz/baz.txt")
        let clientA_commit3 = try await clientA.commit("Third commit")
        try await clientA.push(remote)

        // ClientB: Clone
        try await clientB.clone(remote)
        let clientB_HEAD = await clientB.readHEAD(remote: clientB.remoteLocal)
        #expect(clientB_HEAD == clientA_commit3)

        // ClientA: Second commit
        try await clientA.write("This is some bar", path: "bar.txt")
        try await clientA.commit("Second commit")
        try await clientA.push(remote)
        let clientA_logs = try await clientA.logs()
        #expect(clientA_logs.count == 4)

        try await clientB.rebase(remote)
        let logs = try await clientB.logs()
        #expect(logs.count == 4)
    }

    @Test("Push binaries")
    func pushBinaries() async throws {
        let binaryData = Data("fake image data".utf8)
        let filePath = "photo.jpg"

        // Write binary — should only store locally, not on remote
        try await clientA.writeBinary(binaryData, path: filePath)

        // Read the alias file to get the binary hash
        let aliasData = try await clientA.read("\(filePath).alias")
        let aliasContent = String(data: aliasData, encoding: .utf8)!
        let range = aliasContent.range(of: "Alias-Hash: ")!
        let binaryHash = String(aliasContent[range.upperBound...].prefix(while: { !$0.isWhitespace }))

        // Verify the binary does NOT exist on the remote yet
        let remoteObjects = Objects(remote: remote, objectsPath: await clientA.objectsPath)
        let existsBefore = try await remoteObjects.exists(key: .init(hash: binaryHash, kind: .binary))
        #expect(existsBefore == false)

        // Commit (this commits the alias file as a blob) and push
        try await clientA.commit("Add binary")
        try await clientA.push(remote)

        // Verify the binary now exists on the remote with correct content
        let existsAfter = try await remoteObjects.exists(key: .init(hash: binaryHash, kind: .binary))
        #expect(existsAfter == true)

        let remoteBinary = try await remoteObjects.retrieve(binary: binaryHash)
        #expect(remoteBinary == binaryData)
    }

    @Test("Complex push")
    func pushComplex() async throws {
        try await clientA.write("This is some foo", path: "foo.txt")
        try await clientA.write("This is some bar", path: "bar.txt")
        try await clientA.move("foo.txt", to: "baz/foo.txt")
        try await clientA.commit("First commit")
        try await clientA.push(remote)

        try await clientA.write("This is more foo", path: "baz/foo.txt")
        try await clientA.commit("Second commit")
        try await clientA.push(remote)

        try await clientA.writeBinary(Data("fake image data".utf8), path: "photo.jpg")
        try await clientA.commit("Third commit")
        try await clientA.push(remote)
    }

    @Test("List")
    func list() async throws {
        try await clientA.write("This is some foo", path: "foo.txt")
        try await clientA.commit("First commit")
        try await clientA.push(remote)

        let parent = await clientA.objectsPath
        let items = try await remote.list(path: parent)
        #expect(items.count == 3)

        for item in items {
            #expect(item.hasPrefix(parent))
        }
    }
}
