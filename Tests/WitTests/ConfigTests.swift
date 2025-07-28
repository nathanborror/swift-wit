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

    @Test("Lists")
    func lists() {
        let input = """
            [pins]
                README.md
                Documents/PLAN.txt
            [user]
                name = Test User
            """

        let config = ConfigDecoder().decode(input)
        guard case .array(let items) = config[section: "pins"] else {
            fatalError("missing items")
        }
        #expect(items.count == 2)
    }
}
