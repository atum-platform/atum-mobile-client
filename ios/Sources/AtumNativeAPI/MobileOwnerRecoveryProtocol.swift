import Foundation
import CoreFoundation
import Security

public enum MobileOwnerRecoveryProtocolFailure: Error, Equatable {
    case invalidMessage
    case entropyUnavailable
}

public struct MobileOwnerRecoveryGrant: Sendable, Equatable, CustomStringConvertible,
    CustomDebugStringConvertible
{
    public let nonce: String
    public let transactionID: String
    public let recoveryKey: String
    public let keyID: String

    public var description: String {
        "MobileOwnerRecoveryGrant(<private recovery key withheld>)"
    }

    public var debugDescription: String { description }
}

/// The Matrix verification transaction and remote device that jointly
/// authorize one recovery-key handoff. Once pinned, a concurrent verification
/// request cannot retarget the recovery exchange.
public struct MobileOwnerRecoveryFlow: Sendable, Equatable {
    public let flowID: String
    public let deviceID: String

    public init?(flowID: String, deviceID: String, currentDeviceID: String) {
        guard Self.validPrintable(flowID),
              Self.validPrintable(deviceID),
              deviceID != currentDeviceID else {
            return nil
        }
        self.flowID = flowID
        self.deviceID = deviceID
    }

    private static func validPrintable(_ value: String) -> Bool {
        (1...255).contains(value.utf8.count) &&
            value.utf8.allSatisfy { (33...126).contains($0) }
    }
}

/// Result of observing the SDK's active verification transaction.
///
/// An outgoing Matrix verification starts in `Created`, where the transaction
/// exists but the responding device is not known yet. That is a normal waiting
/// state, not an invalid flow. Once a peer is known, every later observation
/// must preserve the first exact transaction/device pair.
public enum MobileOwnerRecoveryFlowCapture: Sendable, Equatable {
    case pending
    case pinned(MobileOwnerRecoveryFlow)
    case rejected
}

/// Pure admission rules shared by the live adapter and host tests. Matrix
/// supplies transport authentication; the app additionally requires the exact
/// owner, device, SAS transaction and one-time nonce before accepting a key.
public enum MobileOwnerRecoveryAdmission {
    public static func captureFlow(
        existing: MobileOwnerRecoveryFlow?,
        flowID: String?,
        deviceID: String?,
        currentDeviceID: String
    ) -> MobileOwnerRecoveryFlowCapture {
        if flowID == nil, deviceID == nil {
            return existing.map(MobileOwnerRecoveryFlowCapture.pinned) ?? .pending
        }
        guard let flowID, let deviceID,
              let candidate = MobileOwnerRecoveryFlow(
                  flowID: flowID,
                  deviceID: deviceID,
                  currentDeviceID: currentDeviceID
              ), let pinned = pinnedFlow(existing: existing, candidate: candidate) else {
            return .rejected
        }
        return .pinned(pinned)
    }

    public static func pinnedFlow(
        existing: MobileOwnerRecoveryFlow?,
        candidate: MobileOwnerRecoveryFlow
    ) -> MobileOwnerRecoveryFlow? {
        guard let existing else { return candidate }
        return existing == candidate ? existing : nil
    }

    public static func acceptsGrant(
        eventType: String,
        senderID: String,
        authenticatedByStrictShield: Bool,
        authenticatedSenderID: String?,
        authenticatedSenderDeviceID: String?,
        currentUserID: String,
        currentDeviceID: String,
        flow: MobileOwnerRecoveryFlow?,
        nonce: String?,
        alreadyAccepted: Bool,
        grant: MobileOwnerRecoveryGrant
    ) -> Bool {
        guard eventType == MobileOwnerRecoveryProtocol.grantEventType,
              authenticatedByStrictShield,
              senderID == currentUserID,
              authenticatedSenderID == currentUserID,
              let authenticatedSenderDeviceID,
              authenticatedSenderDeviceID != currentDeviceID,
              let flow,
              authenticatedSenderDeviceID == flow.deviceID,
              let nonce,
              !alreadyAccepted,
              grant.nonce == nonce,
              grant.transactionID == flow.flowID else {
            return false
        }
        return true
    }
}

/// One recovery operation may include a final in-flight 30-second SDK request
/// plus the 10-second SDK-readiness poll. The UI deadline therefore remains
/// deliberately wider than the request window instead of expiring at the same
/// instant as the underlying operation.
public enum MobileOwnerRecoveryTiming {
    public static let requestWindowSeconds: TimeInterval = 90
    public static let sdkRequestTimeoutSeconds: TimeInterval = 30
    public static let retryInitialSeconds: TimeInterval = 3
    public static let retryMaximumSeconds: TimeInterval = 30
    public static let readinessPollCount = 40
    public static let readinessPollIntervalSeconds: TimeInterval = 0.25
    public static let operationTimeoutSeconds: TimeInterval = 150
}

/// The small, versioned payload exchanged between two devices immediately
/// after their Matrix SAS verification succeeds. Transport authentication is
/// enforced by the Matrix SDK; this type only creates and parses the exact
/// application payload so extra or malformed fields never reach recovery.
public enum MobileOwnerRecoveryProtocol {
    public static let requestEventType = "io.atum.owner_recovery.request"
    public static let grantEventType = "io.atum.owner_recovery.grant"
    public static let maximumRecoveryKeyBytes = 128

    public static func makeNonce() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw MobileOwnerRecoveryProtocolFailure.entropyUnavailable
        }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    public static func requestContent(nonce: String, transactionID: String) throws -> String {
        guard validNonce(nonce), validPrintable(transactionID) else {
            throw MobileOwnerRecoveryProtocolFailure.invalidMessage
        }
        return try canonicalJSON(["v": 1, "nonce": nonce, "txn": transactionID])
    }

    public static func grantContent(_ content: String) throws -> MobileOwnerRecoveryGrant {
        guard (1...4096).contains(content.utf8.count),
              let data = content.data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(value.keys) == ["v", "nonce", "txn", "recoveryKey", "keyId"],
              isVersionOne(value["v"]),
              let nonce = value["nonce"] as? String,
              let transactionID = value["txn"] as? String,
              let recoveryKey = value["recoveryKey"] as? String,
              let keyID = value["keyId"] as? String,
              validNonce(nonce),
              validPrintable(transactionID),
              (1...maximumRecoveryKeyBytes).contains(recoveryKey.utf8.count),
              recoveryKey.unicodeScalars.allSatisfy({ scalar in
                  scalar.isASCII && (scalar == " " || CharacterSet.alphanumerics.contains(scalar))
              }),
              validPrintable(keyID)
        else {
            throw MobileOwnerRecoveryProtocolFailure.invalidMessage
        }
        return MobileOwnerRecoveryGrant(nonce: nonce,
                                        transactionID: transactionID,
                                        recoveryKey: recoveryKey,
                                        keyID: keyID)
    }

    private static func canonicalJSON(_ value: [String: Any]) throws -> String {
        guard JSONSerialization.isValidJSONObject(value),
              let string = String(
                  data: try JSONSerialization.data(
                      withJSONObject: value,
                      options: [.sortedKeys, .withoutEscapingSlashes]
                  ),
                  encoding: .utf8
              )
        else {
            throw MobileOwnerRecoveryProtocolFailure.invalidMessage
        }
        return string
    }

    private static func validNonce(_ value: String) -> Bool {
        value.range(of: "\\A[A-Za-z0-9_-]{43}\\z", options: .regularExpression) != nil
    }

    private static func isVersionOne(_ value: Any?) -> Bool {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) == CFNumberGetTypeID() else {
            return false
        }
        return number.doubleValue == 1
    }

    private static func validPrintable(_ value: String) -> Bool {
        (1...255).contains(value.utf8.count) &&
            value.utf8.allSatisfy { (33...126).contains($0) }
    }
}
