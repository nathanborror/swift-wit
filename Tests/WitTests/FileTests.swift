import Foundation
import Testing
@testable import Wit

@Suite("File Tests")
final class FileTests {
    
    @Test("FilePath helpers")
    func filePathHelpers() {
        var path: FilePath = "path/to/file.txt"
        #expect(path.lastPathComponent() == "file.txt")
        #expect(path.deletingLastPath() == "path/to")

        path = "path/to"
        #expect(path.lastPathComponent() == "to")
        #expect(path.deletingLastPath() == "path")

        path = "path"
        #expect(path.lastPathComponent() == "path")
        #expect(path.deletingLastPath() == "")

        path = "/path"
        #expect(path.lastPathComponent() == "path")
        #expect(path.deletingLastPath() == "/")
    }
}
