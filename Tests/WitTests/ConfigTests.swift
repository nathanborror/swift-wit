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
                name = Test User
            """

        let config = ConfigDecoder().decode(input)
        #expect(config["core.version"] == "1.0")
        #expect(config["user.name"] == "Test User")
    }

    @Test("Encoding")
    func encoding() {
        let expecting = """
            [core]
                version = 1.0
            [user]
                name = Test User
            """

        let config: [String: Section] = [
            "core": .dictionary(["version": "1.0"]),
            "user": .dictionary(["name": "Test User"]),
        ]

        let encoded = ConfigEncoder().encode(config)
        #expect(encoded == expecting)
    }
}
