import AtumDesign
import Foundation

struct AppOnboardingCopy: Equatable, Sendable {
    private static let root = "src.matrix.mobile-copy.mobileChatCopy.appBot.onboarding"
    private static let consentKey = root + ".consent"
    private static let connectingKey = root + ".connecting"
    private static let failureKey = root + ".failure"
    private static let preferredNameKey = root + ".birth.preferredName"
    private static let birthDateKey = root + ".birth.date"
    private static let birthTimeKey = root + ".birth.time"
    private static let birthTimeHelperKey = root + ".birth.timeHelper"
    private static let birthCityKey = root + ".birth.city"
    private static let genderKey = root + ".birth.gender"
    private static let genderMaleKey = root + ".birth.genderMale"
    private static let genderFemaleKey = root + ".birth.genderFemale"
    private static let readingsKey = root + ".readings"

    let consent: String
    let connecting: String
    let failure: String
    /// The app's terms page when the copy export carries one for it. An app
    /// whose terms the export does not carry shows the consent without a link.
    let termsURL: URL?
    let fieldLabels: [String: String]
    let genderLabels: [String: String]
    let birthTimeHelper: String?
    let readings: String?

    /// The terms page key the export uses for an app (`<slug>TermsURL`).
    private static func termsKey(_ slug: String) -> String { root + "." + slug + "TermsURL" }

    /// Only Moon's intake has labels in the export; any other app's fields use
    /// the labels the provider sends, or a readable form of the field name.
    private static func hasBirthIntakeCopy(_ slug: String) -> Bool { slug == "moon" }

    /// The phone accepts this bundle only when the producer supplied every
    /// required key in every shipped locale. No inline translation fallback is
    /// allowed in Swift. The consent, connecting and failure lines take the
    /// app's name, so they cover every catalog app; Moon and Andy additionally
    /// require their terms page, and any app that ships `<slug>TermsURL`
    /// gets a terms link with no code change.
    init?(catalog: AtumCopy, locale: String, slug: String, appName: String) {
        guard Self.hasCompleteExport(catalog, slug: slug, appName: appName) else { return nil }
        let termsKey = Self.termsKey(slug)
        let termsURL: URL?
        if catalog.contains(termsKey) {
            guard let rawTerms = try? catalog.text(termsKey, locale: locale),
                  let parsed = URL(string: rawTerms), parsed.absoluteString == rawTerms,
                  parsed.scheme == "https", parsed.host != nil, parsed.user == nil,
                  parsed.password == nil, parsed.fragment == nil else { return nil }
            termsURL = parsed
        } else {
            termsURL = nil
        }
        guard let consent = try? catalog.text(Self.consentKey, locale: locale,
                                              arguments: [.text(appName)]),
              let connecting = try? catalog.text(Self.connectingKey, locale: locale,
                                                  arguments: [.text(appName)]),
              let failure = try? catalog.text(Self.failureKey, locale: locale,
                                               arguments: [.text(appName)]) else { return nil }
        self.consent = consent
        self.connecting = connecting
        self.failure = failure
        self.termsURL = termsURL
        if Self.hasBirthIntakeCopy(slug) {
            guard let preferredName = try? catalog.text(Self.preferredNameKey, locale: locale),
                  let birthDate = try? catalog.text(Self.birthDateKey, locale: locale),
                  let birthTime = try? catalog.text(Self.birthTimeKey, locale: locale),
                  let birthTimeHelper = try? catalog.text(Self.birthTimeHelperKey, locale: locale),
                  let birthCity = try? catalog.text(Self.birthCityKey, locale: locale),
                  let gender = try? catalog.text(Self.genderKey, locale: locale),
                  let genderMale = try? catalog.text(Self.genderMaleKey, locale: locale),
                  let genderFemale = try? catalog.text(Self.genderFemaleKey, locale: locale),
                  let readings = try? catalog.text(Self.readingsKey, locale: locale) else { return nil }
            fieldLabels = ["preferred_name": preferredName, "dob": birthDate,
                           "birth_time": birthTime, "birth_city": birthCity,
                           "gender": gender]
            genderLabels = ["male": genderMale, "female": genderFemale]
            self.birthTimeHelper = birthTimeHelper
            self.readings = readings
        } else {
            fieldLabels = [:]
            genderLabels = [:]
            birthTimeHelper = nil
            readings = nil
        }
    }

    /// `birth_city` as “Birth city”: the label for a field the export has no
    /// copy for, so a new app's intake is never shown as a raw identifier.
    static func readableName(_ name: String) -> String {
        let words = name.split(separator: "_").joined(separator: " ")
        return words.prefix(1).uppercased() + words.dropFirst()
    }

    private static func hasCompleteExport(_ catalog: AtumCopy, slug: String,
                                          appName: String) -> Bool {
        var keys = [consentKey, connectingKey, failureKey]
        // Moon and Andy are contractually required to ship a terms page; any
        // other app's is optional but must be complete when present.
        if ["moon", "andy"].contains(slug) || catalog.contains(termsKey(slug)) {
            keys.append(termsKey(slug))
        }
        if hasBirthIntakeCopy(slug) {
            keys += [preferredNameKey, birthDateKey, birthTimeKey, birthTimeHelperKey,
                     birthCityKey, genderKey, genderMaleKey, genderFemaleKey, readingsKey]
        }
        guard keys.allSatisfy(catalog.contains) else { return false }
        for locale in catalog.locales {
            guard (try? catalog.text(consentKey, locale: locale,
                                     arguments: [.text(appName)])) != nil,
                  (try? catalog.text(connectingKey, locale: locale,
                                     arguments: [.text(appName)])) != nil,
                  (try? catalog.text(failureKey, locale: locale,
                                     arguments: [.text(appName)])) != nil else { return false }
            for key in keys where ![consentKey, connectingKey, failureKey].contains(key) {
                guard (try? catalog.text(key, locale: locale)) != nil else { return false }
            }
        }
        return true
    }
}
