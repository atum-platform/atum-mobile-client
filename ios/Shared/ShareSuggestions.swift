import Foundation
import Intents
import UIKit
import AtumNativeAPI

/// Outgoing only; notification donations remain incoming in CommunicationNotification.
@MainActor
enum ShareSuggestions {
    static func preselection(intent: INIntent?, chats: [ShareChat]) -> Set<String> {
        guard let room = (intent as? INSendMessageIntent)?.conversationIdentifier,
              chats.contains(where: { $0.id == room }) else { return [] }
        return [room]
    }
    static func interaction(chat: ShareChat, avatar: Data? = nil) -> INInteraction {
        let image = INImage(imageData: avatar ?? monogram(chat.name))
        let recipients = chat.recipients.map { id in
            INPerson(personHandle: INPersonHandle(value: id, type: .unknown), nameComponents: nil,
                     displayName: chat.isGroup ? id : chat.name, image: image,
                     contactIdentifier: nil, customIdentifier: id)
        }
        let intent = INSendMessageIntent(recipients: recipients, outgoingMessageType: .outgoingMessageText,
                                        content: nil,
                                        speakableGroupName: chat.isGroup ? INSpeakableString(spokenPhrase: chat.name) : nil,
                                        conversationIdentifier: chat.id, serviceName: nil, sender: nil, attachments: nil)
        if chat.isGroup { intent.setImage(image, forParameterNamed: \.speakableGroupName) }
        let interaction = INInteraction(intent: intent, response: nil)
        interaction.direction = .outgoing
        interaction.groupIdentifier = chat.id
        return interaction
    }
    static func delete(roomID: String,
                       perform: (String) async throws -> Void = { try await INInteraction.delete(with: $0) }) async throws {
        try await perform(roomID)
    }
    private static func monogram(_ name: String) -> Data {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: 192, height: 192), format: format).pngData { _ in
            UIColor.systemGray.setFill(); UIBezierPath(ovalIn: CGRect(x: 0, y: 0, width: 192, height: 192)).fill()
            let text = String(name.prefix(1)).uppercased() as NSString
            text.draw(at: CGPoint(x: 64, y: 48), withAttributes: [.font: UIFont.systemFont(ofSize: 72), .foregroundColor: UIColor.white])
        }
    }
}

