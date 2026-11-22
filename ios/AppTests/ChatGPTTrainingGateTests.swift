import AtumDesign
import AtumNativeAPI
import CryptoKit
import XCTest
@testable import AtumMobile

/// The ChatGPT-with-Google training-off confirmation: its words come from the
/// pin, its two recorded sentences are the platform's hashed wording, and a
/// ChatGPT pick is written only when the platform says the confirmation is
/// current.
@MainActor
final class ChatGPTTrainingGateTests: XCTestCase {
    private let connection = "00000000-0000-4000-8000-0000000000c1"

    func testEveryWordOfTheCardComesFromThePin() throws {
        let pin = try AtumCopy()
        for key in ChatGPTTrainingCopyKey.allCases {
            XCTAssertTrue(pin.contains(key.rawValue), "\(key) must come from the pin")
            for locale in pin.locales {
                XCTAssertFalse(try pin.text(key.rawValue, locale: locale).isEmpty, "\(locale) \(key)")
            }
        }
    }

    /// The platform hashes the checkbox and transfer sentences per language
    /// (Shell training-confirmation r3, `docs/operations/chatgpt-training-confirmation.md`).
    /// The phone must show exactly those sentences, character for character.
    func testTheRecordedSentencesAreThePlatformsHashedWording() throws {
        let pin = try AtumCopy()
        let expected: [(String, ChatGPTTrainingCopyKey, String)] = [
            ("en", .checkbox, "aeaa7355a11a0e1865745bad00f82cafe1d7da4c40171ee4209cd1c8fc4e0119"),
            ("vi", .checkbox, "31bc2a143c3ef22bcec6c387d502f909b9df50f023663b2e0cd416de9480ff6b"),
            ("en", .transfer, "b3cafc723f58e153df87996a85a6df782f49c7105925adaee6557d169d932346"),
            ("vi", .transfer, "14b07ec376bc9b16ee2dbf823ca557cbf2c2519d8a765a89f46f636c5c18a14e"),
        ]
        for (locale, key, digest) in expected {
            let sentence = try pin.text(key.rawValue, locale: locale)
            let hash = SHA256.hash(data: Data(sentence.utf8)).map { String(format: "%02x", $0) }.joined()
            XCTAssertEqual(hash, digest, "\(locale) \(key) is not the platform's recorded wording")
        }
        // Every other language reads the English wording, as the platform records it.
        for locale in pin.locales where !["en", "vi"].contains(locale) {
            for key in [ChatGPTTrainingCopyKey.checkbox, .transfer] {
                XCTAssertEqual(try pin.text(key.rawValue, locale: locale),
                               try pin.text(key.rawValue, locale: "en"), "\(locale) \(key)")
            }
        }
    }

    func testAnotherSubscriptionNeverReadsTheConfirmation() async {
        var reads = 0
        let training = ChatGPTTrainingActions(read: { reads += 1; return nil }, confirm: { _ in .unavailable })
        let decision = await ChatGPTTrainingGate.decide(source: .opencodeGo, training: training)
        XCTAssertEqual(decision, .write)
        XCTAssertEqual(reads, 0)
    }

    func testAChatGPTPickWritesOnlyWhenTheConfirmationIsCurrent() async {
        func gate(_ status: ChatGPTTrainingStatus?) async -> ChatGPTTrainingGate.Decision {
            await ChatGPTTrainingGate.decide(
                source: .chatGPTPlan,
                training: ChatGPTTrainingActions(read: { status }, confirm: { _ in .unavailable }))
        }
        let current = ChatGPTTrainingStatus(current: true, connectionID: connection, confirmedAt: Date())
        let missing = ChatGPTTrainingStatus(current: false, connectionID: connection, confirmedAt: nil)
        let decisionCurrent = await gate(current)
        XCTAssertEqual(decisionCurrent, .write)
        let decisionMissing = await gate(missing)
        XCTAssertEqual(decisionMissing, .ask(missing))
        let decisionUnread = await gate(nil)
        XCTAssertEqual(decisionUnread, .failed, "a failed read is never a confirmation")
        let decisionUnwired = await ChatGPTTrainingGate.decide(source: .chatGPTPlan, training: nil)
        XCTAssertEqual(decisionUnwired, .failed, "a picker without the confirmation never writes ChatGPT")
    }
}
