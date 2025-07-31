import Foundation
import Testing
@testable import Wit

@Suite("Config Tests")
final class ConfigTests {

    @Test("Decoding")
    func decoding() {
        let input = """
            [core]
                version = 1.0
            [user]
                name = "Test User"
            """

        let config = ConfigDecoder().decode(input)
        #expect(config["core.version"] == "1.0")
        #expect(config["user.name"] == "Test User")

        guard case .dictionary(let dict) = config[section: "core"] else {
            fatalError("failed to extract dictionary")
        }
        #expect(dict == ["version": "1.0"])
    }

    @Test("Encoding")
    func encoding() {
        let expecting = """
            [core]
                version = 1.0
            [user]
                name = "Test User"
            """

        let config: [String: Section] = [
            "core": .dictionary(["version": "1.0"]),
            "user": .dictionary(["name": "Test User"]),
        ]

        let encoded = ConfigEncoder().encode(config)
        #expect(encoded == expecting)
    }

    @Test("Decoding keyed sections")
    func decodingKeyedSections() {
        let input = """
            [remote "local"]
                host = http://localhost:8080
            """

        let config = ConfigDecoder().decode(input)
        print(config)
        #expect(config["remote:local.host"] == "http://localhost:8080")
    }

    @Test("Encoding keyed sections")
    func encodingKeyedSections() {
        let expecting = """
            [remote "local"]
                host = http://localhost:8080
            """

        let config: [String: Section] = [
            "remote:local": .dictionary(["host": "http://localhost:8080"]),
        ]

        let encoded = ConfigEncoder().encode(config)
        #expect(encoded == expecting)
    }
}
