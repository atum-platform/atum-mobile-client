import Foundation
import UIKit
import AtumChat
import AtumNativeAPI

/// Simulator proof for communication notifications (Debug builds only; see
/// `NotificationService.scriptedFixture`). Each fixture stands in for one SDK
/// notification item and runs the real plan, image normalisation, App Group
/// cache and intent code (Debug simulator builds only; elsewhere `fetched` is
/// generic). Only the SDK fetch and media download are replaced.
enum ScriptedNotificationFixtures {
    enum Fixture: String, CaseIterable {
        case dm, dmMonogram = "dm-monogram", group, channel, channelNoLogo = "channel-no-logo", assistant
    }

    static func fetched(_ fixture: Fixture, roomID: String) async -> FetchedNotification {
        #if DEBUG && targetEnvironment(simulator)
        let own = "@me:fixture.test"
        let (content, input, entry) = values(fixture, roomID: roomID)
        guard let plan = CommunicationNotificationPolicy.plan(input, entry: entry) else {
            return FetchedNotification(result: .content(content), face: nil)
        }
        let image = await CommunicationNotification.image(for: plan, store: try? NotificationSharedStore()) { uri, side in
            guard let data = art(uri: uri, side: side) else { throw CocoaError(.fileNoSuchFile) }
            return data
        }
        let sender = fixture == .dm || fixture == .dmMonogram ? "@mai:fixture.test" : "@linh:fixture.test"
        return FetchedNotification(result: .content(content), face: CommunicationFace(
            plan: plan, roomID: roomID, senderID: sender, senderName: content.senderName,
            ownUserID: own, image: image))
        #else
        return FetchedNotification(result: .generic, face: nil)
        #endif
    }

    #if DEBUG && targetEnvironment(simulator)
    private typealias Values = (RichPushPresentation.Content, CommunicationNotificationPolicy.Input, NotificationRoomEntry?)

    private static func values(_ fixture: Fixture, roomID: String) -> Values {
        func direct(_ name: String, _ body: String, avatar: String?) -> Values {
            (.init(title: name, subtitle: "", body: body, senderName: name),
             .init(roomID: roomID, senderName: name, senderAvatarURI: avatar, roomName: nil,
                   roomAvatarURI: nil, isDirect: true), nil)
        }
        func group(_ room: String, _ body: String, roomAvatar: String?, entry: NotificationRoomEntry?) -> Values {
            (.init(title: room, subtitle: "Linh", body: body, senderName: "Linh", roomName: room),
             .init(roomID: roomID, senderName: "Linh", senderAvatarURI: "mxc://fixture.test/linh",
                   roomName: room, roomAvatarURI: roomAvatar, isDirect: false), entry)
        }
        switch fixture {
        case .dm: return direct("Mai Anh", "Are we still on for dinner at 7?", avatar: "mxc://fixture.test/mai")
        case .dmMonogram: return direct("Mai Anh", "No photo on this profile yet.", avatar: nil)
        case .group: return group("Book club", "Chapter 4 tonight!", roomAvatar: "mxc://fixture.test/bookclub", entry: nil)
        case .channel:
            return group("general", "Standup moved to 10:30.", roomAvatar: nil,
                         entry: .init(kind: .teamChannel, groupName: "# general · Acme Studio",
                                      companyLogoURI: "mxc://fixture.test/acme", companyName: "Acme Studio"))
        case .channelNoLogo:
            return group("design", "New mockups are up.", roomAvatar: nil,
                         entry: .init(kind: .teamChannel, groupName: "# design · Acme Studio",
                                      companyName: "Acme Studio"))
        case .assistant:
            return (.init(title: "Atlas", subtitle: "", body: "Your morning brief is ready.", senderName: "Atlas"),
                    .init(roomID: roomID, senderName: "Atlas", senderAvatarURI: nil, roomName: nil,
                          roomAvatarURI: "mxc://fixture.test/atlas", isDirect: true),
                    .init(kind: .assistant, faceName: "Atlas"))
        }
    }

    /// Stand-in thumbnails: a photo-like portrait, a group photo, a company
    /// logo with transparent corners, an assistant face.
    private static func art(uri: String, side: Int) -> Data? {
        let size = CGSize(width: side, height: side)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        let rect = CGRect(origin: .zero, size: size)
        func portrait(_ top: UIColor, _ bottom: UIColor, _ skin: UIColor) -> Data {
            renderer.jpegData(withCompressionQuality: 0.9) { context in
                let cg = context.cgContext
                let gradient = CGGradient(colorsSpace: nil, colors: [top.cgColor, bottom.cgColor] as CFArray,
                                          locations: [0, 1])!
                cg.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: size.height), options: [])
                skin.setFill()
                cg.fillEllipse(in: CGRect(x: size.width * 0.32, y: size.height * 0.2,
                                          width: size.width * 0.36, height: size.height * 0.4))
                UIColor(white: 0.15, alpha: 1).setFill()
                cg.fillEllipse(in: CGRect(x: size.width * 0.12, y: size.height * 0.62,
                                          width: size.width * 0.76, height: size.height * 0.7))
            }
        }
        switch uri {
        case "mxc://fixture.test/mai":
            return portrait(UIColor(red: 0.98, green: 0.62, blue: 0.45, alpha: 1),
                            UIColor(red: 0.85, green: 0.35, blue: 0.45, alpha: 1),
                            UIColor(red: 0.96, green: 0.84, blue: 0.72, alpha: 1))
        case "mxc://fixture.test/linh":
            return portrait(UIColor(red: 0.45, green: 0.75, blue: 0.95, alpha: 1),
                            UIColor(red: 0.25, green: 0.45, blue: 0.8, alpha: 1),
                            UIColor(red: 0.9, green: 0.76, blue: 0.62, alpha: 1))
        case "mxc://fixture.test/bookclub":
            return renderer.jpegData(withCompressionQuality: 0.9) { context in
                UIColor(red: 0.2, green: 0.55, blue: 0.4, alpha: 1).setFill(); context.fill(rect)
                for (index, color) in [UIColor.systemYellow, .systemRed, .systemBlue, .white].enumerated() {
                    color.setFill()
                    context.fill(CGRect(x: size.width * (0.18 + 0.17 * CGFloat(index)), y: size.height * 0.25,
                                        width: size.width * 0.13, height: size.height * 0.5))
                }
            }
        case "mxc://fixture.test/acme":
            return renderer.pngData { context in
                let cg = context.cgContext
                UIColor(red: 0.12, green: 0.14, blue: 0.2, alpha: 1).setFill()
                UIBezierPath(roundedRect: rect.insetBy(dx: size.width * 0.04, dy: size.height * 0.04),
                             cornerRadius: size.width * 0.24).fill()
                UIColor(red: 1, green: 0.55, blue: 0.1, alpha: 1).setFill()
                cg.move(to: CGPoint(x: size.width * 0.5, y: size.height * 0.2))
                cg.addLine(to: CGPoint(x: size.width * 0.8, y: size.height * 0.78))
                cg.addLine(to: CGPoint(x: size.width * 0.2, y: size.height * 0.78))
                cg.closePath(); cg.fillPath()
            }
        case "mxc://fixture.test/atlas":
            return renderer.pngData { context in
                UIColor(red: 0.93, green: 0.92, blue: 0.97, alpha: 1).setFill(); context.fill(rect)
                UIColor(red: 0.42, green: 0.3, blue: 0.85, alpha: 1).setFill()
                UIBezierPath(ovalIn: rect.insetBy(dx: size.width * 0.22, dy: size.height * 0.22)).fill()
            }
        default: return nil
        }
    }
    #endif
}
