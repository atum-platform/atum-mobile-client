import AtumChat
import AtumNativeAPI
import SwiftUI

// MARK: - Immutable runtime projection

/// The presentation boundary for the signed-in product. These values contain
/// only already-authorized, display-safe data. The Matrix SDK, custody records,
/// requests, retries, and any persistence remain on the other side of this
/// boundary.
struct LiveProductPresentation: Equatable {
    let rooms: LiveProductRoomList
    let store: LiveProductStoreRead
    let notificationPrompt: Bool

    init(rooms: LiveProductRoomList = .loading,
         store: LiveProductStoreRead = .unavailable,
         notificationPrompt: Bool = false) {
        self.rooms = rooms
        self.store = store
        self.notificationPrompt = notificationPrompt
    }
}
enum LiveProductAvailability: Equatable {
    case loading
    case ready
    case empty
    case offline
    case unavailable
}

struct LiveProductRoomList: Equatable {
    let availability: LiveProductAvailability
    let rooms: [LiveProductRoom]

    init(availability: LiveProductAvailability, rooms: [LiveProductRoom] = []) {
        self.availability = availability
        self.rooms = rooms
    }

    static let loading = LiveProductRoomList(availability: .loading)
    static let unavailable = LiveProductRoomList(availability: .unavailable)
}

enum LiveProductRoomKind: Equatable {
    case agent
    case people
    case group
}

enum LiveProductAppVerification: Equatable {
    case official
    case verified
}

/// Server-authored assistant identity carried independently from its avatar
/// and Matrix room. Presentation changes (for example a default assistant
/// photo) must never change roster role or order.
struct LiveProductAssistantMetadata: Equatable {
    let id: String
    let isDefault: Bool
    let order: Int
    /// The platform's assistant slug when `/agents` carries one. It is the
    /// only public-handle-shaped value the phone sees; the alias directory is
    /// not exposed to this client yet.
    var botHandle: String? = nil
}

enum LiveProductAvatar: Equatable {
    /// A remotely hosted assistant photo. The view accepts only HTTPS URLs and
    /// always has a deterministic monogram available while the image loads or
    /// if it cannot be displayed.
    case photo(url: URL, fallback: String)
    case eclipse
    case mark(AgentMark)
    case symbol(String)
    case monogram(String)

    static func fallbackMonogram(for displayName: String) -> String {
        let words = displayName.split(whereSeparator: { $0.isWhitespace })
        let initials = words.prefix(2).compactMap { $0.first }.map(String.init).joined()
        return initials.isEmpty ? "?" : initials.uppercased()
    }
}

extension LiveProductAvatar {
    var agentMark: AgentMark? {
        if case let .mark(value) = self { value } else { nil }
    }
}

struct LiveProductRoom: Identifiable, Equatable {
    let id: String
    let kind: LiveProductRoomKind
    let title: String
    let detail: String?
    let previewContent: RowPreview.Content
    let latestEventAt: Date?
    let latestSenderName: String?
    let latestIsOwn: Bool
    let latestSendState: RowPreview.SendState
    /// The newest event is a delivery-outcome notice. The preview stays the
    /// last real message, and this flag tells the cache merge to keep it.
    var latestWasDeliveryNotice: Bool
    let avatar: LiveProductAvatar?
    let matrixAvatarURL: String?
    let avatarSHA256: String?
    /// Ordered public catalog fallbacks for an app identity. Matrix media is
    /// still preferred when a room supplies it; an undecodable candidate does
    /// not discard the remaining declared URL/digest pairs.
    let avatarCandidates: [LiveProductRemoteArt]
    let appAccent: String?
    let appVerification: LiveProductAppVerification?
    let assistant: LiveProductAssistantMetadata?
    let unreadCount: Int
    let notificationCount: Int
    let highlightCount: Int
    let isMarkedUnread: Bool
    let isPinned: Bool
    let isMuted: Bool
    /// The standard `m.lowpriority` tag: an ordinary chat sinks in the list.
    let isLowPriority: Bool
    let isInvitation: Bool
    let canOpen: Bool
    /// An active agent whose chat room has not reached this phone yet. The row
    /// stays closed and shows the vendored "Getting ready" line.
    let isAwaitingRoom: Bool
    /// The owner's one-to-one room with Moon, Andy or another app bot.
    let isAppBotRoom: Bool
    /// A presentation-only catalog row: it has no room or destination and
    /// must never offer a room action, launch, consent or link operation.
    let isComingSoon: Bool
    /// A live catalog app with a published bot and no chat yet: the row opens
    /// the app's own disclosure flow (`AppStartPolicy`) instead of a room, and
    /// so offers no room action.
    let awaitsStart: Bool
    /// The platform-named Founder's ordinary human chat. Its room is the one
    /// account marker, and only that room may carry this row's official mark.
    let isFounder: Bool
    /// The room's create event carries the company conversation type. A hint
    /// only: such a room shows nowhere unless the platform lists it.
    let claimsConversationType: Bool
    /// The room's own `m.room.avatar`, never a member's (hero) photo: a
    /// company channel's is the company's logo.
    let roomAvatarURL: String?

    init(id: String, kind: LiveProductRoomKind, title: String,
         detail: String? = nil, previewContent: RowPreview.Content = .none,
         latestEventAt: Date? = nil, latestSenderName: String? = nil,
         latestIsOwn: Bool = false, latestSendState: RowPreview.SendState = .sent,
         latestWasDeliveryNotice: Bool = false,
         avatar: LiveProductAvatar? = nil, matrixAvatarURL: String? = nil,
         avatarSHA256: String? = nil,
         avatarCandidates: [LiveProductRemoteArt] = [],
         appAccent: String? = nil, appVerification: LiveProductAppVerification? = nil,
         assistant: LiveProductAssistantMetadata? = nil,
         unreadCount: Int = 0, notificationCount: Int = 0, highlightCount: Int = 0,
         isMarkedUnread: Bool = false, isPinned: Bool = false, isMuted: Bool = false,
         isLowPriority: Bool = false,
         isInvitation: Bool = false, canOpen: Bool = true,
         isAwaitingRoom: Bool = false, isAppBotRoom: Bool = false,
         isComingSoon: Bool = false, awaitsStart: Bool = false,
         isFounder: Bool = false, claimsConversationType: Bool = false,
         roomAvatarURL: String? = nil) {
        self.roomAvatarURL = roomAvatarURL
        self.id = id
        self.kind = kind
        self.title = title
        self.detail = detail
        self.previewContent = previewContent
        self.latestEventAt = latestEventAt
        self.latestSenderName = latestSenderName
        self.latestIsOwn = latestIsOwn
        self.latestSendState = latestSendState
        self.latestWasDeliveryNotice = latestWasDeliveryNotice
        self.avatar = avatar
        self.matrixAvatarURL = matrixAvatarURL
        self.avatarSHA256 = avatarSHA256
        self.avatarCandidates = avatarCandidates
        self.appAccent = appAccent
        self.appVerification = appVerification
        self.assistant = assistant
        self.unreadCount = max(0, unreadCount)
        self.notificationCount = max(0, notificationCount)
        self.highlightCount = max(0, highlightCount)
        self.isMarkedUnread = isMarkedUnread
        self.isPinned = isPinned
        self.isMuted = isMuted
        self.isLowPriority = isLowPriority
        self.isInvitation = isInvitation
        self.canOpen = canOpen
        self.isAwaitingRoom = isAwaitingRoom
        self.isAppBotRoom = isAppBotRoom
        self.isComingSoon = isComingSoon
        self.awaitsStart = awaitsStart
        self.isFounder = isFounder
        self.claimsConversationType = claimsConversationType
    }

    func withRosterState(unreadOverride: Bool? = nil,
                         unreadCountOverride: Int? = nil,
                         notificationCountOverride: Int? = nil,
                         highlightCountOverride: Int? = nil,
                         pinnedOverride: Bool? = nil,
                         mutedOverride: Bool? = nil,
                         lowPriorityOverride: Bool? = nil) -> LiveProductRoom {
        let marksUnread = unreadOverride ?? isMarkedUnread
        let clearsReadState = unreadOverride == false
        return LiveProductRoom(
            id: id, kind: kind, title: title, detail: detail,
            previewContent: previewContent, latestEventAt: latestEventAt,
            latestSenderName: latestSenderName, latestIsOwn: latestIsOwn,
            latestSendState: latestSendState,
            latestWasDeliveryNotice: latestWasDeliveryNotice,
            avatar: avatar,
            matrixAvatarURL: matrixAvatarURL, avatarSHA256: avatarSHA256,
            avatarCandidates: avatarCandidates,
            appAccent: appAccent, appVerification: appVerification,
            assistant: assistant,
            unreadCount: unreadCountOverride ?? (clearsReadState ? 0 : unreadCount),
            notificationCount: notificationCountOverride ?? (clearsReadState ? 0 : notificationCount),
            highlightCount: highlightCountOverride ?? (clearsReadState ? 0 : highlightCount),
            isMarkedUnread: marksUnread,
            isPinned: pinnedOverride ?? isPinned,
            isMuted: mutedOverride ?? isMuted,
            isLowPriority: lowPriorityOverride ?? isLowPriority,
            isInvitation: isInvitation, canOpen: canOpen,
            isAwaitingRoom: isAwaitingRoom, isAppBotRoom: isAppBotRoom,
            isComingSoon: isComingSoon, awaitsStart: awaitsStart, isFounder: isFounder,
            claimsConversationType: claimsConversationType,
            roomAvatarURL: roomAvatarURL
        )
    }
}

enum LiveProductStoreItemKind: Equatable {
    case agent
    case skill
    case pet
}

struct LiveProductRemoteArt: Equatable, Hashable {
    let url: URL
    let sha256: String?
}

/// One installed Store portrait decoded and integrity-checked before its row
/// is projected. Equality follows the immutable inventory identity; the
/// SwiftUI image itself is presentation storage and is intentionally ignored.
struct LiveProductStoreArt: Equatable {
    let resource: String
    let sha256: String
    let value: AtumAvatarArt

    static func == (left: Self, right: Self) -> Bool {
        left.resource == right.resource && left.sha256 == right.sha256
    }
}

struct LiveProductStoreItem: Identifiable, Equatable {
    let id: String
    let kind: LiveProductStoreItemKind
    let title: String
    let summary: String
    let glyph: String
    let featured: Bool
    let price: String?
    let accent: Color?
    /// Installed art selected only by the exported item-ID inventory, decoded
    /// once before this presentation reaches a row.
    let art: LiveProductStoreArt?
    let detailDescription: String
    let tryPrompt: String
    let offer: StoreCatalogOffer?
    let ownership: StoreOwnership?
    let deliverable: Bool?
    let needs: [String]
    let install: StoreHubInstall?

    init(id: String, kind: LiveProductStoreItemKind, title: String, summary: String,
         glyph: String, featured: Bool, price: String?, accent: Color? = nil,
         art: LiveProductStoreArt? = nil, detailDescription: String? = nil, tryPrompt: String = "",
         offer: StoreCatalogOffer? = nil, ownership: StoreOwnership? = nil, deliverable: Bool? = nil,
         needs: [String] = [], install: StoreHubInstall? = nil) {
        self.id = id
        self.kind = kind
        self.title = title
        self.summary = summary
        self.glyph = glyph
        self.featured = featured
        self.price = price
        self.accent = accent
        self.art = art
        self.detailDescription = detailDescription ?? summary
        self.tryPrompt = tryPrompt
        self.offer = offer; self.ownership = ownership; self.deliverable = deliverable
        self.needs = needs; self.install = install
    }
}

struct LiveProductStoreApp: Identifiable, Equatable {
    let id: String
    let title: String
    let subtitle: String?
    /// Ordered server-declared URL/digest pairs. The renderer tries them in
    /// order and falls back to a monogram only after each one fails.
    let avatarCandidates: [LiveProductRemoteArt]
    let accent: Color?
    let isAvailable: Bool
    let isVerified: Bool
    let verification: LiveProductAppVerification?
    /// Only an already joined, listed canonical room may show S6's “Open”.
    let roomID: String?
    /// The effective sidebar state for a presentation-only app. Nil means the
    /// synchronized account-data answer is not authoritative yet, so the UI
    /// offers no guessed write.
    let shortcutVisible: Bool?
    /// Only entries whose shortcut changes presentation without inventing a
    /// live destination expose the reversible Store control.
    let canManageShortcut: Bool
    /// The catalog app has a published bot the phone can take a chat with, but
    /// no room yet. The row offers “Start chat”, which runs the app's
    /// disclosure flow and then opens the chat (`AppStartPolicy`). The slug
    /// is the only thing the root needs to start it; no app is named.
    let canStartChat: Bool
    let slug: String

    init(id: String, title: String, subtitle: String?,
         avatarCandidates: [LiveProductRemoteArt], accent: Color?, isAvailable: Bool,
         isVerified: Bool, verification: LiveProductAppVerification?, roomID: String?,
         shortcutVisible: Bool? = nil, canManageShortcut: Bool = false,
         canStartChat: Bool = false, slug: String? = nil) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.avatarCandidates = avatarCandidates
        self.accent = accent
        self.isAvailable = isAvailable
        self.isVerified = isVerified
        self.verification = verification
        self.roomID = roomID
        self.shortcutVisible = shortcutVisible
        self.canManageShortcut = canManageShortcut
        self.canStartChat = canStartChat
        self.slug = slug ?? id
    }
}

/// Server-authored Store and Apps read projection. Store acquisition state and
/// confirmed commands live in LiveStoreCommerce; card metadata is never authority.
struct LiveProductStoreRead: Equatable {
    let availability: LiveProductAvailability
    /// The wallet's available balance in micro-Protons, formatted only where
    /// it is drawn (`ProtonAmountFormat`), in the app's display language.
    let walletMicroProtons: Int64?
    let items: [LiveProductStoreItem]
    let apps: [LiveProductStoreApp]
    let detail: String?
    let staleAvailability: LiveProductAvailability?

    init(availability: LiveProductAvailability,
         walletMicroProtons: Int64? = nil,
         items: [LiveProductStoreItem] = [],
         apps: [LiveProductStoreApp] = [],
         detail: String? = nil,
         staleAvailability: LiveProductAvailability? = nil) {
        self.availability = availability
        self.walletMicroProtons = walletMicroProtons
        self.items = items
        self.apps = apps
        self.detail = detail
        self.staleAvailability = staleAvailability
    }

    static let unavailable = LiveProductStoreRead(availability: .unavailable)

    /// The balance as every Store and Settings surface shows it: whole
    /// Protons, floored, in `locale`'s digit grouping. Nil while unread.
    func walletText(locale: String) -> String? {
        walletMicroProtons.map { ProtonAmountFormat.balance($0, locale: locale) }
    }
}
