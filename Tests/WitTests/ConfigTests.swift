import Foundation
import Testing
@testable import Wit

@Suite("Config Tests")
final class ConfigTests {

    @Test("Decoding")
    func decoding() {
        let input = """
            [core]
                version = 0.1
            [user]
                name = Test User
            [remote:local]
                host = http://localhost:8080
            [remote:example]
                host = http://example.com
            [files]
                foo.md
                bar.md
            """

        let config = ConfigDecoder().decode(input)
        #expect(config["core.version"] == "0.1")
        #expect(config["user.name"] == "Test User")
        #expect(config["remote:local.host"] == "http://localhost:8080")
        #expect(config[list: "files"]?.count == 2)
        #expect(config[dict: "core"] == ["version": "0.1"])
        #expect(config["files"] == "foo.md\nbar.md")

        let remotes = config[prefix: "remote"]
        #expect(remotes.sections.count == 2)
        #expect(remotes["local.host"] == "http://localhost:8080")
    }

    @Test("Encoding")
    func encoding() {
        let input: [String: Config.Section] = [
            "core": .dictionary(["version": "0.1"]),
            "user": .dictionary(["name": "Test User"]),
            "remote:local": .dictionary(["host": "http://localhost:8080"]),
            "files": .array(["foo.md", "bar.md"]),
        ]
        let encoded = ConfigEncoder().encode(input)

        let expected = """
            [core]
                version = 0.1
            [files]
                foo.md
                bar.md
            [remote:local]
                host = http://localhost:8080
            [user]
                name = Test User
            """
        #expect(encoded == expected)

        let config = ConfigDecoder().decode(encoded)
        #expect(config["core.version"] == "0.1")
        #expect(config["user.name"] == "Test User")
        #expect(config["remote:local.host"] == "http://localhost:8080")
        #expect(config[list: "files"]?.count == 2)
        #expect(config[dict: "core"] == ["version": "0.1"])
    }

    @Test("Empty values")
    func emptyValues() {
        let input: [String: Config.Section] = [
            "core": .dictionary(["version": "0.1"]),
            "user": .dictionary(["name": "", "email": "alice@example.com"]),
        ]

        let encoded = ConfigEncoder().encode(input)
        let expected = """
            [core]
                version = 0.1
            [user]
                email = alice@example.com
            """
        #expect(encoded == expected)
    }

    @Test("Mutations")
    func mutations() {
        var config = Config()
        config["core.version"] = "0.1"
        config["user.name"] = "Test User"
        config["user.email"] = "test@example.com"

        #expect(config["core.version"] == "0.1")
        #expect(config["user.name"] == "Test User")
        #expect(config[section: "user"] != nil)

        config["user.name"] = nil
        #expect(config["user.name"] == nil)

        config[section: "user"] = nil
        #expect(config["user.name"] == nil)
        #expect(config[section: "user"] == nil)
    }
}
