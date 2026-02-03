import Foundation
import CryptoKit
import Testing
@testable import Wit

let isServerRunning = false

@Suite("Remote Tests", .enabled(if: isServerRunning))
final class RemoteTests {
    let privateKey: Remote.PrivateKey
    let identity: String
    let remote: Remote

    let clientA_workingFolder: String
    let clientA: Repo

    let clientB_workingFolder: String
    let clientB: Repo

    init() async throws {
        self.privateKey = Remote.PrivateKey()
        self.identity = UUID().uuidString

        self.clientA_workingFolder = "A-\(identity)"
        self.clientB_workingFolder = "B-\(identity)"

        self.clientA = Repo(baseURL: .documentsDirectory, folder: clientA_workingFolder, privateKey: privateKey)
        try await clientA.initialize()

        let config = """
            Date: \(Date.now.toRFC1123)
            Content-Type: text/ini
            
            identifier = \(identity)
            publicKey = \(privateKey.publicKey.rawRepresentation.base64EncodedString())
            remote = origin
            
            [remote:origin]
            host = "http://localhost:8080"
            kind = local
            """
        try await clientA.write(config, path: Repo.defaultConfigPath)

        self.remote = RemoteHTTP(baseURL: .init(string: "http://localhost:8080/files/\(identity)")!)

        // Register with remote HTTP server
        let registerRemote = RemoteHTTP(baseURL: .init(string: "http://localhost:8080")!)
        let configData = try await clientA.read(Repo.defaultConfigPath)
        try await registerRemote.put(path: "register", data: configData, directoryHint: .notDirectory, privateKey: nil)

        self.clientB = Repo(baseURL: .documentsDirectory, folder: clientB_workingFolder, privateKey: privateKey)
        try await self.clientB.initialize()
    }

    deinit { teardown() }

    func teardown() {
        try? FileManager.default.removeItem(at: .documentsDirectory/clientA_workingFolder)
        try? FileManager.default.removeItem(at: .documentsDirectory/clientB_workingFolder)
        let privateKey = privateKey
        let remote = RemoteHTTP(baseURL: .init(string: "http://localhost:8080/\(identity)")!)
        Task { try await remote.delete(path: "register", privateKey: privateKey) }
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
        let clientB_HEAD = await clientB.readHEAD(remote: clientB.local)
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

    @Test("List")
    func list() async throws {
        try await clientA.write("This is some foo", path: "foo.txt")
        try await clientA.commit("First commit")
        try await clientA.push(remote)

        let parent = "\(Repo.defaultPath)/objects"
        let items = try await remote.list(path: parent)
        #expect(items.count == 3)

        for item in items {
            #expect(item.hasPrefix(parent))
        }
    }
}
