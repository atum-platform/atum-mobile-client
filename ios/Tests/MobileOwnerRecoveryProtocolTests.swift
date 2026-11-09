import XCTest
@testable import AtumNativeAPI

final class MobileOwnerRecoveryProtocolTests: XCTestCase {
    private let nonce = String(repeating: "A", count: 43)
    private let transactionID = "matrix-flow-1"

    func testRequestIsCanonicalAndBoundToNonceAndVerificationFlow() throws {
        XCTAssertEqual(
            try MobileOwnerRecoveryProtocol.requestContent(
                nonce: nonce,
                transactionID: transactionID
            ),
            "{\"nonce\":\"\(nonce)\",\"txn\":\"matrix-flow-1\",\"v\":1}"
        )
        let generated = try MobileOwnerRecoveryProtocol.makeNonce()
        XCTAssertEqual(generated.utf8.count, 43)
        XCTAssertNotNil(generated.range(of: "\\A[A-Za-z0-9_-]{43}\\z", options: .regularExpression))
    }

    func testGrantRequiresTheExactVersionedShape() throws {
        let recoveryKey = "EsTc Qm9Q private root"
        let content = """
        {"keyId":"PUBLIC_FIXTU","nonce":"\(nonce)","recoveryKey":"\(recoveryKey)","txn":"\(transactionID)","v":1}
        """
        let grant = try MobileOwnerRecoveryProtocol.grantContent(content)
        XCTAssertEqual(grant.nonce, nonce)
        XCTAssertEqual(grant.transactionID, transactionID)
        XCTAssertEqual(grant.recoveryKey, recoveryKey)
        XCTAssertEqual(grant.keyID, "PUBLIC_FIXTU")
        XCTAssertFalse(String(reflecting: grant).contains(recoveryKey))
    }

    func testMalformedOrExtendedMessagesFailClosed() throws {
        let valid: [String: Any] = [
            "v": 1,
            "nonce": nonce,
            "txn": transactionID,
            "recoveryKey": "recovery key",
            "keyId": "current-key",
        ]
        let invalid: [[String: Any]] = [
            valid.merging(["extra": "field"]) { _, new in new },
            valid.merging(["v": 2]) { _, new in new },
            valid.merging(["v": true]) { _, new in new },
            valid.merging(["nonce": String(repeating: "A", count: 42)]) { _, new in new },
            valid.merging(["txn": "contains a space"]) { _, new in new },
            valid.merging(["recoveryKey": "punctuation!"]) { _, new in new },
            valid.merging(["recoveryKey": String(repeating: "A", count: 129)]) { _, new in new },
            valid.merging(["keyId": "contains a space"]) { _, new in new },
        ]
        for value in invalid {
            let content = String(decoding: try JSONSerialization.data(withJSONObject: value), as: UTF8.self)
            XCTAssertThrowsError(try MobileOwnerRecoveryProtocol.grantContent(content))
        }
        XCTAssertThrowsError(
            try MobileOwnerRecoveryProtocol.requestContent(
                nonce: String(repeating: "x", count: 42),
                transactionID: transactionID
            )
        )
    }

    func testFlowPinsFirstExactRemoteDeviceAndTransaction() throws {
        let first = try XCTUnwrap(MobileOwnerRecoveryFlow(
            flowID: transactionID,
            deviceID: "DESKTOP1",
            currentDeviceID: "PHONE1"
        ))
        XCTAssertEqual(MobileOwnerRecoveryAdmission.pinnedFlow(existing: nil,
                                                               candidate: first), first)
        XCTAssertEqual(MobileOwnerRecoveryAdmission.pinnedFlow(existing: first,
                                                               candidate: first), first)
        let competing = try XCTUnwrap(MobileOwnerRecoveryFlow(
            flowID: "matrix-flow-2",
            deviceID: "DESKTOP2",
            currentDeviceID: "PHONE1"
        ))
        XCTAssertNil(MobileOwnerRecoveryAdmission.pinnedFlow(existing: first,
                                                             candidate: competing))
        XCTAssertNil(MobileOwnerRecoveryFlow(flowID: "contains a space",
                                             deviceID: "DESKTOP1",
                                             currentDeviceID: "PHONE1"))
        XCTAssertNil(MobileOwnerRecoveryFlow(flowID: transactionID,
                                             deviceID: "PHONE1",
                                             currentDeviceID: "PHONE1"))
    }

    func testOutgoingFlowWaitsForPeerThenPinsTheExactPair() throws {
        XCTAssertEqual(
            MobileOwnerRecoveryAdmission.captureFlow(
                existing: nil,
                flowID: nil,
                deviceID: nil,
                currentDeviceID: "PHONE1"
            ),
            .pending
        )

        let first = try XCTUnwrap(MobileOwnerRecoveryFlow(
            flowID: transactionID,
            deviceID: "DESKTOP1",
            currentDeviceID: "PHONE1"
        ))
        XCTAssertEqual(
            MobileOwnerRecoveryAdmission.captureFlow(
                existing: nil,
                flowID: transactionID,
                deviceID: "DESKTOP1",
                currentDeviceID: "PHONE1"
            ),
            .pinned(first)
        )
        XCTAssertEqual(
            MobileOwnerRecoveryAdmission.captureFlow(
                existing: first,
                flowID: nil,
                deviceID: nil,
                currentDeviceID: "PHONE1"
            ),
            .pinned(first)
        )
        XCTAssertEqual(
            MobileOwnerRecoveryAdmission.captureFlow(
                existing: first,
                flowID: "matrix-flow-2",
                deviceID: "DESKTOP2",
                currentDeviceID: "PHONE1"
            ),
            .rejected
        )
        XCTAssertEqual(
            MobileOwnerRecoveryAdmission.captureFlow(
                existing: nil,
                flowID: transactionID,
                deviceID: nil,
                currentDeviceID: "PHONE1"
            ),
            .rejected
        )
    }

    func testGrantAdmissionRequiresExactAuthenticatedBinding() throws {
        let flow = try XCTUnwrap(MobileOwnerRecoveryFlow(
            flowID: transactionID,
            deviceID: "DESKTOP1",
            currentDeviceID: "PHONE1"
        ))
        let grant = try MobileOwnerRecoveryProtocol.grantContent("""
        {"keyId":"current-key","nonce":"\(nonce)","recoveryKey":"recovery key","txn":"\(transactionID)","v":1}
        """)
        func accepts(
            eventType: String = MobileOwnerRecoveryProtocol.grantEventType,
            senderID: String = "@owner:atum.test",
            authenticated: Bool = true,
            authenticatedSenderID: String? = "@owner:atum.test",
            authenticatedDeviceID: String? = "DESKTOP1",
            candidateFlow: MobileOwnerRecoveryFlow? = flow,
            candidateNonce: String? = nonce,
            alreadyAccepted: Bool = false,
            candidateGrant: MobileOwnerRecoveryGrant? = nil
        ) -> Bool {
            MobileOwnerRecoveryAdmission.acceptsGrant(
                eventType: eventType,
                senderID: senderID,
                authenticatedByStrictShield: authenticated,
                authenticatedSenderID: authenticatedSenderID,
                authenticatedSenderDeviceID: authenticatedDeviceID,
                currentUserID: "@owner:atum.test",
                currentDeviceID: "PHONE1",
                flow: candidateFlow,
                nonce: candidateNonce,
                alreadyAccepted: alreadyAccepted,
                grant: candidateGrant ?? grant
            )
        }
        XCTAssertTrue(accepts())
        XCTAssertFalse(accepts(eventType: "io.atum.other"))
        XCTAssertFalse(accepts(senderID: "@other:atum.test"))
        XCTAssertFalse(accepts(authenticated: false))
        XCTAssertFalse(accepts(authenticatedSenderID: "@other:atum.test"))
        XCTAssertFalse(accepts(authenticatedDeviceID: "DESKTOP2"))
        XCTAssertFalse(accepts(authenticatedDeviceID: "PHONE1"))
        XCTAssertFalse(accepts(candidateFlow: nil))
        XCTAssertFalse(accepts(candidateNonce: nil))
        XCTAssertFalse(accepts(alreadyAccepted: true))

        let wrongNonce = try MobileOwnerRecoveryProtocol.grantContent("""
        {"keyId":"current-key","nonce":"\(String(repeating: "B", count: 43))","recoveryKey":"recovery key","txn":"\(transactionID)","v":1}
        """)
        XCTAssertFalse(accepts(candidateGrant: wrongNonce))
        let wrongTransaction = try MobileOwnerRecoveryProtocol.grantContent("""
        {"keyId":"current-key","nonce":"\(nonce)","recoveryKey":"recovery key","txn":"matrix-flow-2","v":1}
        """)
        XCTAssertFalse(accepts(candidateGrant: wrongTransaction))
    }

    func testRecoveryOperationDeadlineOutlivesRequestAndReadinessWork() {
        let worstCase = MobileOwnerRecoveryTiming.requestWindowSeconds +
            MobileOwnerRecoveryTiming.sdkRequestTimeoutSeconds +
            MobileOwnerRecoveryTiming.readinessPollIntervalSeconds *
            Double(MobileOwnerRecoveryTiming.readinessPollCount)
        XCTAssertGreaterThan(MobileOwnerRecoveryTiming.operationTimeoutSeconds, worstCase)
        XCTAssertEqual(MobileOwnerRecoveryProtocol.maximumRecoveryKeyBytes, 128)
    }
}
