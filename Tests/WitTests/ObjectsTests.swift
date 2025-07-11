import Foundation
import Testing
@testable import Wit

@Suite("Objects Tests")
final class ObjectsTests {

    var baseURL: URL
    var remote: Remote
    var storage: Objects

    init() async throws {
        self.baseURL = .documentsDirectory/UUID().uuidString
        self.remote = RemoteDisk(baseURL: baseURL)
        self.storage = Objects(remote: remote, objectsPath: ".wild/objects")
    }

    deinit {
        try? FileManager.default.removeItem(at: baseURL)
    }

    @Test("Blob storage")
    func simpleBlobStorage() async throws {
        let content = "Hello, World!"

        let blob = Blob(string: content)
        let blobHash = try await storage.store(blob, privateKey: nil)
        #expect(blobHash != "")

        let blobObj = try await storage.retrieve(blobHash)
        #expect(blobObj.kind == .blob)
        #expect(String(data: blobObj.content, encoding: .utf8) == content)

        let identicalBlob = Blob(string: content)
        let identicalBlobHash = try await storage.store(identicalBlob, privateKey: nil)
        #expect(identicalBlobHash == blobHash)
    }

    @Test("Blob compression")
    func largeBlobCompression() async throws {
        let content = """
        When in the Course of human events, it becomes necessary for one people to dissolve the political bands which have \
        connected them with another, and to assume among the powers of the earth, the separate and equal station to which \
        the Laws of Nature and of Nature's God entitle them, a decent respect to the opinions of mankind requires that \
        they should declare the causes which impel them to the separation.

        We hold these truths to be self-evident, that all men are created equal, that they are endowed by their Creator \
        with certain unalienable Rights, that among these are Life, Liberty and the pursuit of Happiness.--That to secure \
        these rights, Governments are instituted among Men, deriving their just powers from the consent of the governed, \
        —That whenever any Form of Government becomes destructive of these ends, it is the Right of the People to alter \
        or to abolish it, and to institute new Government, laying its foundation on such principles and organizing its \
        powers in such form, as to them shall seem most likely to effect their Safety and Happiness. Prudence, indeed, \
        will dictate that Governments long established should not be changed for light and transient causes; and \
        accordingly all experience hath shewn, that mankind are more disposed to suffer, while evils are sufferable, than \
        to right themselves by abolishing the forms to which they are accustomed. But when a long train of abuses and \
        usurpations, pursuing invariably the same Object evinces a design to reduce them under absolute Despotism, it is \
        their right, it is their duty, to throw off such Government, and to provide new Guards for their future security.\
        —Such has been the patient sufferance of these Colonies; and such is now the necessity which constrains them to \
        alter their former Systems of Government. The history of the present King of Great Britain is a history of \
        repeated injuries and usurpations, all having in direct object the establishment of an absolute Tyranny over \
        these States. To prove this, let Facts be submitted to a candid world.
        """

        let blob = Blob(string: content)
        let blobHash = try await storage.store(blob, privateKey: nil)
        #expect(blobHash != "")

        let blobObj = try await storage.retrieve(blobHash)
        let blobContent = String(data: blobObj.content, encoding: .utf8)
        #expect(blobObj.kind == .blob)
        #expect(blobContent == content)

        let identicalBlob = Blob(string: content)
        let identicalBlobHash = try await storage.store(identicalBlob, privateKey: nil)
        #expect(identicalBlobHash == blobHash)
    }

    @Test("Tree storage")
    func treeStorage() async throws {
        let blob = Blob(string: "Hello, World!")
        let blobHash = try await storage.store(blob, privateKey: nil)

        let tree = Tree(entries: [
            .init(
                mode: .normal,
                name: "README.md",
                hash: blobHash
            ),
        ])
        let treeHash = try await storage.store(tree, privateKey: nil)
        #expect(treeHash != "")

        let treeObj = try await storage.retrieve(treeHash)
        #expect(treeObj.kind == .tree)
//        #expect(treeObj.content == tree.content)
    }

    @Test("Commit storage")
    func commitStorage() async throws {
        let blob = Blob(string: "Hello, World!")
        let blobHash = try await storage.store(blob, privateKey: nil)
        let tree = Tree(entries: [.init(mode: .normal, name: "README.md", hash: blobHash)])
        let treeHash = try await storage.store(tree, privateKey: nil)

        let commitTimestamp = Date.now
        let commit = Commit(
            tree: treeHash,
            parent: "",
            author: "Nathan Borror <nathan@nathan.run>",
            message: "Initial commit",
            timestamp: commitTimestamp
        )
        let commitHash = try await storage.store(commit, privateKey: nil)
        #expect(commitHash != "")

        let commitObj = try await storage.retrieve(commitHash)
        #expect(commitObj.kind == .commit)
//        #expect(commitObj.content == commit.content)
    }

    @Test("Hashing")
    func hashing() async throws {
        let content = "Hello, World!"
        let blob = Blob(string: content)
        let url = baseURL/"test.txt"

        try FileManager.default.mkdir(url)
        try content.write(to: url, atomically: true, encoding: .utf8)

        let blobHeader = storage.header(kind: "blob", count: blob.content.count)
        let blobData = blobHeader + blob.content
        let blobHash = storage.hashCompute(blobData)

        let memoryMappedHash = try storage.hash(for: url)
        #expect(blobHash == memoryMappedHash)
    }

    private func commitDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = Commit.dateFormat
        return formatter.string(from: date)
    }
}
