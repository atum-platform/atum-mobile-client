import Foundation
import XCTest
@testable import AtumNativeAPI

final class AliasContactsTests: XCTestCase {
    func testRequestBoundsUniquenessAndContactIdentityShape() throws {
        XCTAssertThrowsError(try AliasContactsRequest(matrixUsers: []))
        XCTAssertThrowsError(try AliasContactsRequest(matrixUsers: Array(repeating: "@person:example.test", count: 2)))
        XCTAssertThrowsError(try AliasContactsRequest(matrixUsers: (0..<51).map { "@person-\($0):example.test" }))
        for bad in ["bad", "@Upper:example.test", "@person:example.test\n", "@person:example.test?query", "@" + String(repeating: "x", count: 255) + ":example.test"] {
            XCTAssertThrowsError(try AliasContactsRequest(matrixUsers: [bad]), bad)
        }
        XCTAssertNoThrow(try AliasContactsRequest(matrixUsers: ["@person:example.test:8448"]))
    }

    func testVersionedContactsRequireClosedCoherentEvidence() throws {
        let valid = #"{"contacts":[{"matrixUser":"@person:example.test","handle":"person_handle","status":"resolved","generation":1}],"schemaVersion":2,"revision":0}"#
        XCTAssertNoThrow(try NativeAPI.decode(AliasContactsResponse.self, from: Data(valid.utf8)))
        for bad in [
            valid.replacingOccurrences(of: #""resolved""#, with: #""unknown""#),
            valid.replacingOccurrences(of: #""generation":1"#, with: #""generation":null"#),
            valid.replacingOccurrences(of: #""generation":1"#, with: #""generation":1.0"#),
            valid.replacingOccurrences(of: #""revision":0"#, with: #""revision":-1"#),
            valid.replacingOccurrences(of: #""schemaVersion":2"#, with: #""schemaVersion":3"#),
            valid.replacingOccurrences(of: #""handle":"person_handle""#, with: #""handle":"@person_handle""#),
            valid.replacingOccurrences(of: #""revision":0"#, with: #""revision":0,"extra":true"#)
        ] {
            XCTAssertThrowsError(try NativeAPI.decode(AliasContactsResponse.self, from: Data(bad.utf8)))
        }
    }

    func testLegacyAndVersionedShapesCannotBeMixed() throws {
        for bad in [
            #"{"contacts":[{"matrixUser":"@person:example.test","handle":null}],"schemaVersion":2,"revision":1}"#,
            #"{"contacts":[{"matrixUser":"@person:example.test","handle":null,"status":"unknown","generation":null}]}"#,
            #"{"contacts":[{"matrixUser":"@person:example.test","handle":null}],"revision":1}"#,
            #"{"contacts":[{"matrixUser":"@person:example.test"}]}"#
        ] {
            XCTAssertThrowsError(try NativeAPI.decode(AliasContactsResponse.self, from: Data(bad.utf8)))
        }
    }
}
