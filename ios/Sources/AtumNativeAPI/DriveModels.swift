import CryptoKit
import Foundation

public enum DriveContract {
    public static let id = "atum.mobile-drive/1"
    public static let digest = "1b7a3a2d4bc41efe361449327874c38c594393a7828861b2f2811e256a54139e"
    public static let discoveryURL = URL(
        string: "https://auth.atumplatform.com/.well-known/openid-configuration"
    )!
    public static let accountURL = URL(
        string: "https://api.atumplatform.com/api/matrix/v1/drive/account"
    )!
    static let forbiddenProviderFields: Set<String> = [
        "clientSecret", "client_secret", "accessToken", "refreshToken",
        "subject", "principal", "owner", "opencloudUserId", "personalSpaceId",
        "rawError", "stderr",
    ]
    /// Raw LibreGraph metadata legitimately contains `owner`, user IDs and
    /// parent references. Reject only credential-bearing keys at this
    /// boundary; typed decoders ignore every other unknown metadata field.
    static let forbiddenRawGraphFields: Set<String> = [
        "accessToken", "access_token", "refreshToken", "refresh_token",
        "clientSecret", "client_secret", "token", "Token", "credential", "Credential",
        "password", "Password", "secret", "authorization", "Authorization",
    ]
}

public enum DriveAccountState: String, Codable, CaseIterable, Sendable {
    case provisioning, active, suspended, deleting, deleted
}

public struct DriveClientRegistration: Equatable, Sendable {
    public let clientID: String

    public static func decode(_ data: Data) throws -> Self {
        do {
            let value = try NativeAPI.decode(
                Payload.self,
                from: data,
                forbidden: DriveContract.forbiddenProviderFields
            )
            return DriveClientRegistration(clientID: value.clientID)
        } catch {
            throw DriveFailure.invalidResponse
        }
    }

    private struct Payload: Decodable {
        let clientID: String

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Field.self)
            try c.closed([
                "client_id", "client_name", "client_auth_method", "redirect_uris",
                "scopes", "pkce_method", "state", "nonce", "dynamic_registration",
            ])
            clientID = try c.string(
                "client_id", minimum: 26, maximum: 26,
                pattern: "[0-9A-HJKMNP-TV-Z]{26}"
            )
            guard clientID == MASPublicClients.drive,
                  try c.value("client_name", as: String.self) == "Atum for iPhone (Drive)",
                  try c.value("client_auth_method", as: String.self) == "none",
                  try c.value("redirect_uris", as: [String].self)
                    == [MASPublicClients.callback.absoluteString],
                  try c.value("scopes", as: [String].self) == ["openid"],
                  try c.value("pkce_method", as: String.self) == "S256",
                  try c.value("state", as: Bool.self),
                  try c.value("nonce", as: Bool.self),
                  try !c.value("dynamic_registration", as: Bool.self) else {
                throw ContractViolation.invariant
            }
        }
    }
}

public struct DriveAdmission: Equatable, Sendable {
    public let clientID: String

    public static func decode(_ data: Data) throws -> Self {
        do {
            let value = try NativeAPI.decode(
                Payload.self,
                from: data,
                forbidden: DriveContract.forbiddenProviderFields
            )
            return DriveAdmission(clientID: value.clientID)
        } catch {
            throw DriveFailure.invalidResponse
        }
    }

    private struct Payload: Decodable {
        let clientID: String

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Field.self)
            try c.closed(["active", "tokenType", "clientId", "scope"])
            guard try c.value("active", as: Bool.self),
                  try c.value("tokenType", as: String.self) == "access_token",
                  try c.value("scope", as: String.self) == "openid" else {
                throw ContractViolation.invariant
            }
            clientID = try c.string(
                "clientId", minimum: 26, maximum: 26,
                pattern: "[0-9A-HJKMNP-TV-Z]{26}"
            )
            guard [MASPublicClients.drive, "01JDRVCMPNXQ7R8S9T0V2W3X4Y"].contains(clientID) else {
                throw ContractViolation.invariant
            }
        }
    }
}

public struct DriveAccount: Equatable, Sendable {
    public let state: DriveAccountState
    public let serverURL: URL

    public static func decode(_ data: Data) throws -> Self {
        do {
            return try NativeAPI.decode(
                Payload.self,
                from: data,
                forbidden: DriveContract.forbiddenProviderFields
            ).value
        } catch {
            throw DriveFailure.invalidResponse
        }
    }

    private struct Payload: Decodable {
        let value: DriveAccount

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Field.self)
            try c.closed(["state", "serverUrl"])
            let state = try c.value("state", as: DriveAccountState.self)
            let raw = try c.string("serverUrl", minimum: 9, maximum: 2_048)
            guard let url = URL(string: raw), url.absoluteString == raw,
                  url.scheme == "https", url.host?.isEmpty == false,
                  url.port == nil, url.user == nil, url.password == nil,
                  url.path == "", url.query == nil, url.fragment == nil else {
                throw ContractViolation.invalidValue
            }
            value = DriveAccount(state: state, serverURL: url)
        }
    }
}

public enum DriveItemKind: String, Codable, Sendable {
    case file, folder
}

public struct DriveItem: Codable, Equatable, Hashable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let kind: DriveItemKind
    public let etag: String
    public let size: Int64
    /// The file's WebDAV address, which is what a download reads. OpenCloud
    /// omits it on folders in a children listing (seen on the owner's personal
    /// root, 2026-11-04); folders are browsed by `id`, so they may lack it.
    /// A file without one is refused.
    public let webDavURL: URL?
    public let modifiedAt: Date?
    public let mimeType: String?
    public let parentDriveID: String?
    public let parentID: String?

    public init(id: String, name: String, kind: DriveItemKind, etag: String,
                size: Int64, webDavURL: URL?, modifiedAt: Date? = nil,
                mimeType: String? = nil, parentDriveID: String? = nil,
                parentID: String? = nil) throws {
        self.id = try checkedString(id, minimum: 1, maximum: 1_024)
        self.name = try checkedString(
            name,
            minimum: 1,
            maximum: 255,
            pattern: "[^/\\\\\\u0000-\\u001f]+"
        )
        self.kind = kind
        self.etag = try checkedString(etag, minimum: 1, maximum: 1_024)
        guard (0...NativeAPI.maximumInteger).contains(size),
              kind == .folder || webDavURL != nil else {
            throw ContractViolation.invalidValue
        }
        if let webDavURL {
            guard webDavURL.scheme == "https", webDavURL.host?.isEmpty == false,
                  webDavURL.user == nil, webDavURL.password == nil,
                  webDavURL.fragment == nil,
                  webDavURL.path.hasPrefix("/dav/spaces/") else {
                throw ContractViolation.invalidValue
            }
        }
        self.size = size
        self.webDavURL = webDavURL
        self.modifiedAt = modifiedAt
        if let mimeType {
            self.mimeType = try checkedString(mimeType, minimum: 1, maximum: 255)
        } else {
            self.mimeType = nil
        }
        self.parentDriveID = try parentDriveID.map {
            try checkedString($0, minimum: 3, maximum: 512)
        }
        self.parentID = try parentID.map {
            try checkedString($0, minimum: 1, maximum: 1_024)
        }
    }

    enum CodingKeys: String, CodingKey {
        case id, name, kind, etag, size, webDavURL = "webDavUrl", modifiedAt, mimeType
        case parentDriveID, parentID
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let all = Set(c.allKeys)
        let allowed: Set<CodingKeys> = [.id, .name, .kind, .etag, .size, .webDavURL,
                                        .modifiedAt, .mimeType, .parentDriveID, .parentID]
        guard all.isSubset(of: allowed) else { throw ContractViolation.unknownField }
        try self.init(
            id: c.decode(String.self, forKey: .id),
            name: c.decode(String.self, forKey: .name),
            kind: c.decode(DriveItemKind.self, forKey: .kind),
            etag: c.decode(String.self, forKey: .etag),
            size: c.decode(Int64.self, forKey: .size),
            webDavURL: c.decodeIfPresent(URL.self, forKey: .webDavURL),
            modifiedAt: c.decodeIfPresent(Date.self, forKey: .modifiedAt),
            mimeType: c.decodeIfPresent(String.self, forKey: .mimeType),
            parentDriveID: c.decodeIfPresent(String.self, forKey: .parentDriveID),
            parentID: c.decodeIfPresent(String.self, forKey: .parentID)
        )
    }
}

public struct DrivePage: Codable, Equatable, Sendable {
    /// A stable local key for the personal root. It is not sent to the server.
    public static let rootParentID = "__atum_personal_drive_root__"

    public let driveID: String
    public let parentID: String
    public let items: [DriveItem]
    public let isTruncated: Bool

    public init(driveID: String, parentID: String, items: [DriveItem],
                isTruncated: Bool = false) throws {
        self.driveID = try checkedString(
            driveID,
            minimum: 3,
            maximum: 512,
            pattern: "[!-#%-~]+[$][!-#%-~]+"
        )
        self.parentID = try checkedString(parentID, minimum: 1, maximum: 1_024)
        guard items.count <= 5_000, Set(items.map(\.id)).count == items.count else {
            throw ContractViolation.invalidValue
        }
        self.items = items
        self.isTruncated = isTruncated
    }

    private enum CodingKeys: String, CodingKey {
        case driveID, parentID, items, isTruncated
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            driveID: c.decode(String.self, forKey: .driveID),
            parentID: c.decode(String.self, forKey: .parentID),
            items: c.decode([DriveItem].self, forKey: .items),
            isTruncated: c.decodeIfPresent(Bool.self, forKey: .isTruncated) ?? false
        )
    }

    /// Decodes the frozen `ios.drive_page` fixture shape. Incomplete pages are
    /// rejected, so an error can never overwrite a last-good listing.
    public static func decodeContract(_ data: Data) throws -> Self {
        do {
            return try NativeAPI.decode(
                ContractPayload.self,
                from: data,
                forbidden: DriveContract.forbiddenProviderFields
            ).page
        } catch {
            throw DriveFailure.invalidResponse
        }
    }

    private struct ContractPayload: Decodable {
        let page: DrivePage

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Field.self)
            try c.closed(["driveId", "parentId", "complete", "items", "nextCursor"])
            guard try c.value("complete", as: Bool.self) else {
                throw ContractViolation.invariant
            }
            page = try DrivePage(
                driveID: c.string("driveId", minimum: 3, maximum: 512),
                parentID: c.string("parentId", minimum: 1, maximum: 1_024),
                items: c.value("items"),
                isTruncated: false
            )
            if let cursor: String = try c.optional("nextCursor") {
                _ = try checkedString(cursor, minimum: 1, maximum: 4_096)
            }
        }
    }
}

public struct DriveSpace: Equatable, Sendable, Identifiable {
    public let id: String
    public let name: String

    public init(id: String, name: String) throws {
        self.id = try checkedString(id, minimum: 3, maximum: 512)
        self.name = try checkedString(name, minimum: 1, maximum: 255)
    }
}

public struct DriveDownload: Equatable, Sendable {
    public let itemID: String
    public let etag: String
    public let size: Int64
    public let webDavURL: URL

    public static func decodeContract(_ data: Data) throws -> Self {
        do {
            return try NativeAPI.decode(
                Payload.self,
                from: data,
                forbidden: DriveContract.forbiddenProviderFields
            ).value
        } catch {
            throw DriveFailure.invalidResponse
        }
    }

    private struct Payload: Decodable {
        let value: DriveDownload

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Field.self)
            try c.closed(["itemId", "etag", "size", "webDavUrl", "atomic"])
            guard try c.value("atomic", as: Bool.self) else {
                throw ContractViolation.invariant
            }
            let itemID = try c.string("itemId", minimum: 1, maximum: 1_024)
            let etag = try c.string("etag", minimum: 1, maximum: 1_024)
            let size = try c.integer("size")
            let rawURL = try c.string("webDavUrl", minimum: 30, maximum: 4_096)
            guard let url = URL(string: rawURL), url.absoluteString == rawURL,
                  url.scheme == "https", url.host?.isEmpty == false,
                  url.path.hasPrefix("/dav/spaces/") else {
                throw ContractViolation.invalidValue
            }
            value = DriveDownload(itemID: itemID, etag: etag, size: size, webDavURL: url)
        }
    }
}

public struct DriveDenial: Equatable, Sendable {
    public let status: Int
    public let reason: DriveDenialReason
    public let retryAfter: Int?

    public static func decodeContract(_ data: Data) throws -> Self {
        do {
            return try NativeAPI.decode(
                Payload.self,
                from: data,
                forbidden: DriveContract.forbiddenProviderFields
            ).value
        } catch {
            throw DriveFailure.invalidResponse
        }
    }

    private struct Payload: Decodable {
        let value: DriveDenial

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Field.self)
            try c.closed(["status", "reason", "retryAfter"])
            let status = Int(try c.integer("status"))
            guard [400, 401, 403, 404, 503].contains(status) else {
                throw ContractViolation.invalidValue
            }
            let reason = try c.value("reason", as: DriveDenialReason.self)
            let retry = try c.optional("retryAfter", as: WireInteger.self)?.value
            guard retry.map({ (1...300).contains($0) }) ?? true else {
                throw ContractViolation.invalidValue
            }
            value = DriveDenial(status: status, reason: reason, retryAfter: retry.map(Int.init))
        }
    }
}

/// Opaque local namespace derived from the already-verified account binding.
/// Cache paths and metadata never contain the issuer, subject or principal.
public struct DriveCacheScope: Hashable, Sendable {
    public let key: String

    public init(issuer: String, subject: String, principal: NativeID) throws {
        guard let issuerURL = URL(string: issuer), issuerURL.scheme == "https",
              !subject.isEmpty, subject.utf8.count <= 1_024 else {
            throw DriveFailure.invalidAccount
        }
        let material = Data((issuer + "\u{0}" + subject + "\u{0}" + principal.rawValue).utf8)
        key = SHA256.hash(data: material).map { String(format: "%02x", $0) }.joined()
    }

    public init(account: OIDCRestoredAccount) throws {
        try self.init(issuer: account.issuer, subject: account.subject,
                      principal: account.principal)
    }
}

public enum DriveDenialReason: String, Codable, Sendable {
    case missingToken = "missing_token"
    case inactive, expired
    case wrongClient = "wrong_client"
    case wrongScope = "wrong_scope"
    case wrongIssuer = "wrong_issuer"
    case unsupportedCredential = "unsupported_credential"
    case notAllowed = "not_allowed"
    case notProvisioned = "not_provisioned"
    case notHuman = "not_human"
    case suspended, notOwner = "not_owner"
    case routeNotAllowed = "route_not_allowed"
    case invalidPath = "invalid_path"
    case invalidDestination = "invalid_destination"
    case depthNotAllowed = "depth_not_allowed"
    case publicLinksDisabled = "public_links_disabled"
    case provisioning
    case providerUnavailable = "provider_unavailable"
    case quota
    case unknown

    var requiresAuthentication: Bool {
        switch self {
        case .missingToken, .inactive, .expired, .wrongClient, .wrongScope, .wrongIssuer,
             .unsupportedCredential:
            true
        default:
            false
        }
    }
}

public enum DriveFailure: Error, Equatable, Sendable {
    case invalidAccount
    case invalidRequest
    case invalidResponse
    case responseTooLarge
    case redirectRefused
    case offline
    case timedOut
    case secureConnectionFailed
    case serviceUnavailable(retryAfter: Int?)
    case rateLimited(retryAfter: Int?)
    case cancelled
    case reauthenticationRequired
    case denied(DriveDenialReason)
    case provisioning(retryAfter: Int?)
    case providerUnavailable
    case notFound
    case changed
    case serverQuota
    case lowDisk
    case storageUnavailable

    public var isTemporarilyUnavailable: Bool {
        switch self {
        case .serviceUnavailable, .rateLimited: true
        default: false
        }
    }
}
