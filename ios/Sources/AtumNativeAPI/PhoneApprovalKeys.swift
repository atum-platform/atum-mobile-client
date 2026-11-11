import Foundation
import CryptoKit
import Security
import LocalAuthentication

public enum PhoneKeyRole: String { case identity, approval }
public enum PhoneApprovalFailure: Error { case setupRequired, cancelled, authenticationFailed, keychain(OSStatus), invalidBody }
/// Implementations must return DER SPKI and IEEE P1363 signatures. Software keys belong in tests only.
public protocol PhoneApprovalKeyStore {
    func create(_ role: PhoneKeyRole) throws
    func publicKey(_ role: PhoneKeyRole) throws -> Data
    func sign(_ bytes: Data, role: PhoneKeyRole, reason: String) throws -> Data
    func remove(_ role: PhoneKeyRole) throws
}
public extension Data {
    var phoneBase64URL: String { base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") }
}
public enum PhoneEnrollment {
    public static func keyID(spki: Data) -> String { Data(SHA256.hash(data: spki)).phoneBase64URL }
    public static func canonicalBytes(body: Data) throws -> Data {
        try EnrollmentJSON.check(body)
        guard let object = try JSONSerialization.jsonObject(with: body) as? [String: Any],
              object["platform"] as? String == "ios",
              let scopes = object["scopes"] as? [Any], scopes.isEmpty else { throw PhoneApprovalFailure.invalidBody }
        try validate(object)
        let json = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        return Data("atum.device-service.v1\0EnrollDevice\0".utf8) + json
    }
    public static func request(body: Data, keys: PhoneApprovalKeyStore, rotatingFrom previous: PhoneApprovalKeyStore? = nil, reason: String) throws -> Data {
        let bytes = try canonicalBytes(body: body)
        let fields = try JSONSerialization.jsonObject(with: body) as! [String: Any]
        guard fields["identityKey"] as? String == (try keys.publicKey(.identity)).phoneBase64URL,
              fields["approvalKey"] as? String == (try keys.publicKey(.approval)).phoneBase64URL,
              (fields["previousApprovalKid"] == nil) == (previous == nil) else { throw PhoneApprovalFailure.invalidBody }
        if let previous {
            guard fields["previousApprovalKid"] as? String == keyID(spki: try previous.publicKey(.approval)) else { throw PhoneApprovalFailure.invalidBody }
        }
        var sigs = ["identity": try keys.sign(bytes, role: .identity, reason: reason).phoneBase64URL,
                    "approval": try keys.sign(bytes, role: .approval, reason: reason).phoneBase64URL]
        if let previous { sigs["previousApproval"] = try previous.sign(bytes, role: .approval, reason: reason).phoneBase64URL }
        return try JSONSerialization.data(withJSONObject: ["body": JSONSerialization.jsonObject(with: body), "sigs": sigs], options: [.sortedKeys, .withoutEscapingSlashes])
    }
}
/// Namespace must be installation/account specific. Never silently recreate a missing enrolled key.
public final class SecureEnclavePhoneKeyStore: PhoneApprovalKeyStore {
    private let namespace: String
    public init(namespace: PhoneKeyNamespace) { self.namespace = namespace.value }
    private func query(_ role: PhoneKeyRole) -> [String: Any] {
        [kSecClass as String: kSecClassKey, kSecAttrApplicationTag as String: Data((namespace + "." + role.rawValue).utf8), kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom]
    }
    public func create(_ role: PhoneKeyRole) throws {
        // Explicit setup only: never append a second key under an existing tag.
        var lookup = query(role)
        lookup[kSecReturnAttributes as String] = true
        lookup[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
        let existing = SecItemCopyMatching(lookup as CFDictionary, nil)
        guard existing == errSecItemNotFound else { throw PhoneApprovalFailure.keychain(existing == errSecSuccess ? errSecDuplicateItem : existing) }
        let flags: SecAccessControlCreateFlags = role == .approval ? [.privateKeyUsage, .userPresence] : [.privateKeyUsage]
        var error: Unmanaged<CFError>?
        guard let acl = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly, flags, &error) else { throw PhoneApprovalFailure.setupRequired }
        let attributes: [String: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom, kSecAttrKeySizeInBits as String: 256, kSecAttrTokenID as String: kSecAttrTokenIDSecureEnclave,
            kSecPrivateKeyAttrs as String: [kSecAttrIsPermanent as String: true, kSecAttrApplicationTag as String: Data((namespace + "." + role.rawValue).utf8), kSecAttrAccessControl as String: acl]]
        guard SecKeyCreateRandomKey(attributes as CFDictionary, &error) != nil else { throw PhoneApprovalFailure.setupRequired }
    }
    private func key(_ role: PhoneKeyRole, reason: String? = nil) throws -> SecKey {
        var q = query(role)
        q[kSecReturnRef as String] = true
        let context = LAContext()
        context.touchIDAuthenticationAllowableReuseDuration = 0
        if let reason { context.localizedReason = reason }
        q[kSecUseAuthenticationContext as String] = context
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecUserCanceled { throw PhoneApprovalFailure.cancelled }
        guard status == errSecSuccess, let result else { throw PhoneApprovalFailure.setupRequired }
        return result as! SecKey
    }
    public func publicKey(_ role: PhoneKeyRole) throws -> Data {
        guard let publicKey = SecKeyCopyPublicKey(try key(role)), let raw = SecKeyCopyExternalRepresentation(publicKey, nil) as Data? else { throw PhoneApprovalFailure.setupRequired }
        return try P256.Signing.PublicKey(x963Representation: raw).derRepresentation
    }
    public func sign(_ bytes: Data, role: PhoneKeyRole, reason: String) throws -> Data {
        var error: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(try key(role, reason: reason), .ecdsaSignatureMessageX962SHA256, bytes as CFData, &error) as Data? else {
            if let failure = error?.takeRetainedValue() {
                let code = CFErrorGetCode(failure)
                if code == Int(errSecUserCanceled) || (CFErrorGetDomain(failure) as String == LAError.errorDomain && [LAError.userCancel.rawValue, LAError.systemCancel.rawValue, LAError.appCancel.rawValue].contains(code)) {
                    throw PhoneApprovalFailure.cancelled
                }
            }
            throw PhoneApprovalFailure.authenticationFailed
        }
        return try P256.Signing.ECDSASignature(derRepresentation: signature).rawRepresentation
    }
    public func remove(_ role: PhoneKeyRole) throws {
        let status = SecItemDelete(query(role) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw PhoneApprovalFailure.keychain(status) }
    }
}

public struct PhoneRegistryError: Decodable, Error {
    public enum Code: String, Decodable { case invalid = "matrix_400", unauthenticated = "matrix_401", forbidden = "matrix_403", notFound = "matrix_404", conflict = "matrix_409", unavailable = "matrix_503" }
    public struct Details: Decodable { public let reason: String? }
    public let error: Code
    public let details: Details?
}
public extension PhoneEnrollment {
    static func decodeBase64URL(_ value: String) throws -> Data {
        guard value.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) == value.startIndex..<value.endIndex,
              let data = Data(base64Encoded: value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/") + String(repeating: "=", count: (4 - value.count % 4) % 4)),
              data.phoneBase64URL == value else { throw PhoneApprovalFailure.invalidBody }
        return data
    }
    static func validate(_ object: [String: Any]) throws {
        let required: Set<String> = ["deviceServiceId", "displayName", "platform", "osVersion", "identityKey", "approvalKey", "matrix", "enrollmentEpoch", "scopes", "controllerKeys", "issuedAt"]
        func matches(_ value: Any?, _ expression: String) -> Bool {
            guard let value = value as? String else { return false }
            return value.range(of: expression, options: .regularExpression) == value.startIndex..<value.endIndex
        }
        func integer(_ value: Any?, minimum: Int64) -> Bool {
            guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return false }
            return number.doubleValue >= Double(minimum) && number.doubleValue <= 9_007_199_254_740_991 && number.doubleValue.rounded() == number.doubleValue
        }
        guard required.isSubset(of: Set(object.keys)), Set(object.keys).isSubset(of: required.union(["previousApprovalKid"])),
              matches(object["deviceServiceId"], "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"),
              matches(object["displayName"], "^[^\\x00-\\x1f\\x7f]{1,64}$"),
              (object["displayName"] as? String)?.utf16.count ?? 100 <= 64,
              matches(object["osVersion"], "^[0-9]+(?:[.][0-9]+)*$"), (object["osVersion"] as? String)?.count ?? 100 > 0,
              (object["osVersion"] as? String)?.count ?? 100 <= 32,
              integer(object["issuedAt"], minimum: 0), integer(object["enrollmentEpoch"], minimum: 1),
              let matrix = object["matrix"] as? [String: Any], Set(matrix.keys) == ["userId", "deviceId", "fingerprint"],
              matches(matrix["userId"], "^@[!-9;-~]+:[!-~]+$"), (matrix["userId"] as? String)?.count ?? 2000 <= 1024,
              matches(matrix["deviceId"], "^[!-~]{1,255}$"), matches(matrix["fingerprint"], "^[A-Za-z0-9+/]{43}$"),
              let controllers = object["controllerKeys"] as? [String], (1...8).contains(controllers.count), Set(controllers).count == controllers.count,
              controllers.allSatisfy({ matches($0, "^[A-Za-z0-9_-]{43}$") }),
              let identity = object["identityKey"] as? String, let approval = object["approvalKey"] as? String, identity != approval, identity.count == 122, approval.count == 122 else { throw PhoneApprovalFailure.invalidBody }
        for encoded in [identity, approval] {
            let data = try decodeBase64URL(encoded)
            let parsed = try P256.Signing.PublicKey(derRepresentation: data)
            guard parsed.derRepresentation == data else { throw PhoneApprovalFailure.invalidBody }
        }
        let epoch = (object["enrollmentEpoch"] as! NSNumber).int64Value
        guard (epoch == 1 && object["previousApprovalKid"] == nil) || (epoch > 1 && matches(object["previousApprovalKid"], "^[A-Za-z0-9_-]{43}$")) else { throw PhoneApprovalFailure.invalidBody }
    }
}

private enum EnrollmentJSON {
    /// Reject duplicate members before Foundation can collapse them, including escaped names.
    static func check(_ data: Data) throws {
        guard data.count <= 32_768, String(data: data, encoding: .utf8) != nil else { throw PhoneApprovalFailure.invalidBody }
        let bytes = Array(data)
        var objects: [Set<String>] = []
        var index = 0
        while index < bytes.count {
            if bytes[index] == 123 { objects.append([]) }
            else if bytes[index] == 125 { guard !objects.isEmpty else { throw PhoneApprovalFailure.invalidBody }; objects.removeLast() }
            else if bytes[index] == 34 {
                let start = index
                index += 1
                while index < bytes.count && bytes[index] != 34 {
                    if bytes[index] == 92 { index += 1 }
                    index += 1
                }
                guard index < bytes.count else { throw PhoneApprovalFailure.invalidBody }
                var after = index + 1
                while after < bytes.count && [9,10,13,32].contains(bytes[after]) { after += 1 }
                if after < bytes.count && bytes[after] == 58 {
                    let name = try JSONDecoder().decode(String.self, from: Data(bytes[start...index]))
                    guard !objects.isEmpty, objects[objects.count - 1].insert(name).inserted else { throw PhoneApprovalFailure.invalidBody }
                }
            }
            index += 1
        }
    }
}
