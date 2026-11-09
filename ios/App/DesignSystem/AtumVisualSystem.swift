import SwiftUI

/// Palette roles exported by `phone-design.json` that new app surfaces may use.
///
/// Keeping this closed makes an unknown palette key a compile-time error at a
/// call site. `LiveDesign` remains the single runtime source for the values.
enum AtumColorRole: String, CaseIterable, Sendable {
    case ground
    case cell
    case bubble
    case frame
    case ink
    case soft
    case muted
    case danger
    case glassOpaque
    case onInk
    case eclipseTile
    case avatarEdge
    case onDanger
    case actionStrong
    case actionQuiet
    case viewerGround
    case viewerInk
    case mediaScrim
    case onAccent
}

/// SF Symbol aliases exported by the design bundle and used by this shared
/// system. Views must not embed a raw SF Symbol name.
enum AtumGlyph: String, Sendable, CaseIterable {
    case arrowUpRight = "ArrowUpRight"
    case alertCircle = "AlertCircle"
    case bell = "Bell"
    case bellOff = "BellOff"
    case briefcase = "Briefcase"
    case check = "Check"
    case checkCircle = "CheckCircle2"
    case chevronDown = "ChevronDown"
    case chevronRight = "ChevronRight"
    case clock = "Clock"
    case close = "X"
    case cloudOff = "CloudOff"
    case compass = "Compass"
    case compassFilled = "CompassFilled"
    case composePencil = "ComposePencil"
    case copy = "Copy"
    case eye = "Eye"
    case deviceMobile = "DeviceMobile"
    case fileText = "FileText"
    case folder = "Folder"
    case folderFilled = "FolderFilled"
    case globe = "Globe"
    case home = "Home"
    case homeFilled = "HomeFilled"
    case helpCircle = "HelpCircle"
    case history = "History"
    case keyRound = "KeyRound"
    case messageCircle = "MessageCircle"
    case link = "Link"
    case logOut = "LogOut"
    case mail = "Mail"
    case mailOpened = "MailOpened"
    case moreHorizontal = "MoreHorizontal"
    case pencil = "Pencil"
    case pawPrint = "PawPrint"
    case photo = "Photo"
    case pin = "Pin"
    case pinFilled = "PinFilled"
    case pinOff = "PinOff"
    case plus = "Plus"
    case rosetteCheck = "RosetteCheck"
    case rosetteCheckFilled = "RosetteCheckFilled"
    case search = "Search"
    case settings = "Settings"
    case shield = "Shield"
    case slidersHorizontal = "SlidersHorizontal"
    case sparkles = "Sparkles"
    case star = "Star"
    case trash = "Trash2"
    case userCircle = "UserCircle"
    case userCircleFilled = "UserCircleFilled"
    case users = "Users"
    // Phone-local aliases for Kit board glyphs (phosphor-map.json); the
    // shared glyphs.json has no Tabler name for them.
    case arrowBackUp = "ArrowBackUp"
    case briefcaseFilled = "BriefcaseFilled"
    case chevronLeft = "ChevronLeft"
    case chevronUpDown = "ChevronUpDown"
    case circle = "Circle"
    case eyeOff = "EyeOff"
    case file = "File"
    case hash = "Hash"
    case info = "Info"
    case messageCircleFilled = "MessageCircleFilled"
    case smiley = "Smiley"
    case sun = "Sun"
    case starFilled = "StarFilled"
    case thumbsUp = "ThumbsUp"
    case user = "User"
}

/// Copy identifiers required by shared decorative controls. They are resolved
/// by the committed production copy bundle, never embedded as localised text.
enum AtumCopyKey: String, Sendable {
    case officialApp = "src.matrix.founder.founder-copy.FOUNDER_COPY.officialApp"
    case officialAccount = "src.matrix.founder.founder-copy.FOUNDER_COPY.officialAccount"
    case verifiedApp = "desktop.atum.roster.verified"
    /// The phone's own "Not now" (AtumAskCard's secondary action).
    case notNow = "src.matrix.mobile-copy.mobilePhoneCopy.notNow"
}

/// The typed projection of the live design bundle supplied once by a screen
/// root. It gives views typed colour, glyph and copy access without changing
/// `LiveDesign`'s legacy string API for existing S1 surfaces.
@MainActor
struct AtumVisualSystem {
    let design: LiveDesign

    init(design: LiveDesign) {
        self.design = design
    }

    func color(_ role: AtumColorRole, scheme: ColorScheme) -> Color {
        design.color(role.rawValue, scheme: scheme)
    }

    /// Atum Kit tokens, for surfaces drawn to the Kit boards.
    var kit: AtumKit { design.kit }

    func kitColor(_ role: AtumKit.ColorRole, scheme: ColorScheme) -> Color {
        design.kit.color(role, scheme: scheme)
    }

    /// The Phosphor custom symbol's asset name: draw it with `Image(_:)` or
    /// `Label(_:image:)`, never `Image(systemName:)` (STYLE §8).
    func symbol(_ glyph: AtumGlyph) -> String {
        design.symbol(glyph.rawValue)
    }

    func text(_ key: AtumCopyKey) -> String {
        design.text(key.rawValue)
    }
}

extension EnvironmentValues {
    /// Installed at an app or feature root with
    /// `.atumDesign(design)`.
    ///
    /// It is optional while legacy S1 roots migrate. New S2+ views that use it
    /// deliberately render no design-dependent element until their owning root
    /// supplies the live bundle, rather than inventing a fallback palette.
    @Entry var atum: AtumVisualSystem?
}
