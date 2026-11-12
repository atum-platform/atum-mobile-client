// Communication-notification shape adapted from Element X iOS's Apache-2.0
// `UNMutableNotificationContent.addSenderIcon` and `NotificationContentBuilder.icon(for:)`.
// Copyright 2023 New Vector Ltd. Modifications Copyright 2026 Anka Ventures Vietnam Company Limited.
// Licensed under the Apache License, Version 2.0; see Vendor/Notices/ElementX-NSE.md.
import CoreGraphics
import Foundation
import ImageIO
import Intents
import UIKit
import UniformTypeIdentifiers
import UserNotifications
import AtumChat
import AtumNativeAPI

/// The plan and its loaded image, resolved inside the fetch while the SDK
/// client is alive. Plain values only: it crosses tasks.
struct CommunicationFace: Sendable, Equatable {
    let plan: CommunicationNotificationPolicy.Plan
    let roomID: String
    let senderID: String
    /// The validated sender name (`RichPushPresentation.Content.senderName`).
    let senderName: String
    let ownUserID: String
    /// PNG or JPEG bytes ready for `INImage`, or nil for the monogram.
    let image: Data?
}

/// The fetched presentation and, when it has a sender, its communication face.
struct FetchedNotification: Sendable {
    let result: RichPushPresentation.Result
    let face: CommunicationFace?
}

/// Why the communication step kept the plain rich content. Closed public codes.
enum CommunicationFallback: String {
    case noPlan = "no_plan", donationFailed = "donation_failed", updateFailed = "update_failed"
}

enum CommunicationNotification {
    /// The side of the avatar image handed to iOS, in pixels. The banner and
    /// lock-screen faces are under 64 pt, so 3x of 64 covers them.
    static let pixelSide = 192
    /// Each avatar fetch, and the donation, get this long; the whole fetch
    /// keeps its own 20-second gate.
    static let fetchSeconds = 2.0
    static let donationSeconds = 2.0

    /// Element X's mapping: a person's face rides on the sender `INPerson`;
    /// a group's on `speakableGroupName`, with the sender and me as recipients.
    static func intent(for face: CommunicationFace, image: INImage) -> INSendMessageIntent {
        let isGroup: Bool
        let groupName: String?
        switch face.plan.style {
        case .person: isGroup = false; groupName = nil
        case let .group(name): isGroup = true; groupName = name
        }
        let sender = INPerson(personHandle: INPersonHandle(value: face.senderID, type: .unknown),
                              nameComponents: nil, displayName: senderName(face),
                              image: isGroup ? nil : image, contactIdentifier: nil, customIdentifier: nil)
        var recipients: [INPerson]?
        if isGroup {
            let me = INPerson(personHandle: INPersonHandle(value: face.ownUserID, type: .unknown),
                              nameComponents: nil, displayName: nil, image: nil,
                              contactIdentifier: nil, customIdentifier: nil, isMe: true)
            recipients = [sender, me]
        }
        let intent = INSendMessageIntent(recipients: recipients, outgoingMessageType: .outgoingMessageText,
                                         content: nil,
                                         speakableGroupName: groupName.map { INSpeakableString(spokenPhrase: $0) },
                                         conversationIdentifier: face.roomID, serviceName: nil,
                                         sender: sender, attachments: nil)
        if isGroup { intent.setImage(image, forParameterNamed: \.speakableGroupName) }
        return intent
    }

    /// The communication content, or nil to keep `content` as it is. Never
    /// throws: an avatar or intent failure only costs the big image.
    static func apply(_ face: CommunicationFace, to content: UNNotificationContent,
                      donate: @escaping @Sendable (INInteraction) async throws -> Void = { try await $0.donate() },
                      log: (CommunicationFallback) -> Void = { _ in }) async -> UNNotificationContent? {
        guard let data = face.image ?? monogram(face.plan.monogramName) else { log(.noPlan); return nil }
        let intent = intent(for: face, image: INImage(imageData: data))
        let interaction = InteractionBox(INInteraction(intent: intent, response: nil))
        interaction.value.direction = .incoming
        let donated = await firstOf(seconds: donationSeconds) {
            try await donate(interaction.value)
            return true
        }
        if donated == nil { log(.donationFailed) }
        do { return try content.updating(from: intent) }
        catch { log(.updateFailed); return nil }
    }

    private static func senderName(_ face: CommunicationFace) -> String {
        switch face.plan.style {
        case .person: face.plan.monogramName
        case .group: face.senderName
        }
    }

    /// The plan's image: the app's drawn face from the shared store, else a
    /// cached or freshly fetched SDK thumbnail (one URI at a time, each with a
    /// short deadline), else nil for the monogram.
    static func image(for plan: CommunicationNotificationPolicy.Plan, store: NotificationSharedStore?,
                      thumbnail: @escaping @Sendable (String, Int) async throws -> Data) async -> Data? {
        let side = pixelSide
        // At most two network reads: the time budget is the gate's, not ours.
        var fetches = 0
        for source in plan.images {
            if Task.isCancelled { return nil }
            switch source {
            case let .appFace(name):
                if let data = store?.readFace(name), let image = normalized(data) {
                    return image
                }
            case let .matrix(uri):
                if let cached = store?.cachedAvatar(uri: uri, pixelSide: side) { return cached }
                guard fetches < 2 else { continue }
                fetches += 1
                guard let data = await firstOf(seconds: fetchSeconds, {
                    try await thumbnail(uri, side)
                }), let image = normalized(data) else { continue }
                store?.storeAvatar(image, uri: uri, pixelSide: side)
                return image
            }
        }
        return nil
    }

    // MARK: Images

    /// The app's monogram (Atum Kit: the light `monogram` gradient, top to
    /// bottom, and a white semibold initial at 37% of the side), in a circle.
    static func monogram(_ name: String, side: Int = pixelSide) -> Data? {
        let size = CGSize(width: side, height: side)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            let rect = CGRect(origin: .zero, size: size)
            context.cgContext.addEllipse(in: rect)
            context.cgContext.clip()
            let colors = MonogramGradient.light.map {
                CGColor(srgbRed: $0.red, green: $0.green, blue: $0.blue, alpha: 1)
            } as CFArray
            if let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors,
                                         locations: [0, 1]) {
                context.cgContext.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: size.height),
                                                     options: [])
            }
            let initial = AvatarMonogram.text(for: name) as NSString
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: CGFloat(side) * 0.37, weight: .semibold),
                .foregroundColor: UIColor.white,
            ]
            let textSize = initial.size(withAttributes: attributes)
            initial.draw(at: CGPoint(x: (size.width - textSize.width) / 2, y: (size.height - textSize.height) / 2),
                         withAttributes: attributes)
        }
        return image.pngData()
    }

    /// A fetched thumbnail decoded at no more than `pixelSide` and re-encoded
    /// small: JPEG for an opaque photo, PNG when a logo has transparency.
    /// Undecodable bytes are refused, so a bad image falls through.
    static func normalized(_ data: Data, side: Int = pixelSide) -> Data? {
        guard data.count <= 4 * 1_024 * 1_024,
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: side,
              ] as CFDictionary) else { return nil }
        let opaque = [.none, .noneSkipFirst, .noneSkipLast].contains(image.alphaInfo)
        let output = NSMutableData()
        let type = (opaque ? UTType.jpeg : UTType.png).identifier as CFString
        guard let destination = CGImageDestinationCreateWithData(output, type, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image,
                                   opaque ? [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary : nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }

    // MARK: Deadlines

    /// The operation's value, or nil once `seconds` pass. Unlike a task group
    /// it does not wait for an SDK call that ignores cancellation.
    static func firstOf<T: Sendable>(seconds: Double,
                                     _ operation: @escaping @Sendable () async throws -> T) async -> T? {
        let gate = ResumeOnce<T?>()
        return await withCheckedContinuation { continuation in
            gate.set(continuation)
            let work = Task { gate.resume(try? await operation()) }
            Task {
                try? await Task.sleep(for: .seconds(seconds))
                work.cancel()
                gate.resume(nil)
            }
        }
    }
}

/// The Kit's light `monogram` gradient stops (`atum-kit-tokens.json`,
/// `gradients.light.monogram`). A notification image is one bitmap for both
/// appearances, so it uses the light pair; `NotificationServiceTests` checks
/// these against the vendored tokens.
enum MonogramGradient {
    struct Stop: Equatable { let red, green, blue: Double }
    static let light = [Stop(red: 169 / 255, green: 173 / 255, blue: 181 / 255),
                        Stop(red: 134 / 255, green: 138 / 255, blue: 147 / 255)]
}

/// `INInteraction` is not Sendable; it is built here and only read by the donation.
private struct InteractionBox: @unchecked Sendable {
    let value: INInteraction
    init(_ value: INInteraction) { self.value = value }
}

private final class ResumeOnce<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Never>?
    private var pending: T?
    private var done = false

    func set(_ continuation: CheckedContinuation<T, Never>) {
        let early: T? = lock.withLock {
            if done, let pending { self.pending = nil; return pending }
            self.continuation = continuation
            return nil
        }
        if let early { continuation.resume(returning: early) }
    }

    func resume(_ value: T) {
        let target: CheckedContinuation<T, Never>? = lock.withLock {
            guard !done else { return nil }
            done = true
            if let continuation { self.continuation = nil; return continuation }
            pending = value
            return nil
        }
        target?.resume(returning: value)
    }
}
