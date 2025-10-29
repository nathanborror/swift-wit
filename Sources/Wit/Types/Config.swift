import Foundation

public struct Config {
    public var version: String
    public var picture: String?
    public var remoteDefault: String?
    public var remotes: [String: Remote]

    public struct Remote {
        public var kind: Kind
        public var host: String?
        public var bucket: String?
        public var path: String?
        public var region: String?
        public var accessKey: String?
        public var secretKey: String?

        public enum Kind: String {
            case wild
            case s3
        }

        public init(kind: Kind, host: String? = nil, bucket: String? = nil, path: String? = nil, region: String? = nil, accessKey: String? = nil, secretKey: String? = nil) {
            self.kind = kind
            self.host = host
            self.bucket = bucket
            self.path = path
            self.region = region
            self.accessKey = accessKey
            self.secretKey = secretKey
        }
    }

    public init(version: String = "0.1", picture: String? = nil, remoteDefault: String? = nil, remotes: [String: Remote] = [:]) {
        self.version = version
        self.picture = picture
        self.remoteDefault = remoteDefault
        self.remotes = remotes
    }

    public static var empty: Config { .init() }
}
