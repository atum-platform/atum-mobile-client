import Foundation
import MatrixRustSDK

/// One of the person's other devices, as Settings › Your devices lists it
/// (desktop `security-panel.tsx` `DevicesPanel`). The device ID is the handle
/// for signing it out and is never drawn: a row shows the name the device gave
/// itself, else "Another device", and when it was last active.
struct AccountDevice: Identifiable, Equatable, Sendable {
    /// The Matrix device ID. Identity only; never shown.
    let id: String
    /// The name the device gave itself, when it is a readable name.
    let name: String?
    let lastSeen: Date?
}

/// Settings › Your devices, as read from the homeserver.
enum AccountDeviceLoad: Equatable, Sendable {
    case loading
    case failed
    case loaded([AccountDevice])
}

/// The person's own sessions from `GET /_matrix/client/v3/devices`, without
/// this phone's: its row is "This iPhone" above them. Only the ID, the display
/// name and the last-seen time are kept; the last-seen IP is dropped unread.
enum AccountDeviceList {
    static let maximum = 100

    private struct Response: Decodable {
        struct Device: Decodable {
            let device_id: String
            let display_name: String?
            let last_seen_ts: Int64?
        }
        let devices: [Device]
    }

    /// Nil when the body is not a device list: an unreadable answer is a
    /// failed read, never an empty one.
    static func parse(_ data: Data, currentDeviceID: String) -> [AccountDevice]? {
        guard let response = try? JSONDecoder().decode(Response.self, from: data) else { return nil }
        let devices = response.devices
            .filter { !$0.device_id.isEmpty && $0.device_id != currentDeviceID }
            .prefix(maximum)
            .map { device in
                AccountDevice(
                    id: device.device_id,
                    name: readableName(device.display_name, deviceID: device.device_id),
                    lastSeen: device.last_seen_ts.flatMap { $0 > 0 ? Date(timeIntervalSince1970: Double($0) / 1_000) : nil }
                )
            }
        // Most recently active first; never-seen last, then a stable order.
        return devices.sorted { left, right in
            switch (left.lastSeen, right.lastSeen) {
            case let (l?, r?) where l != r: return l > r
            case (.some, nil): return true
            case (nil, .some): return false
            default: return left.id < right.id
            }
        }
    }

    /// The device's own name, or nil when it would expose an identifier: an
    /// empty name, the device ID itself, or a Matrix ID (`@user:server`).
    static func readableName(_ raw: String?, deviceID: String) -> String? {
        guard let name = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty,
              name != deviceID, name.unicodeScalars.count <= 128,
              !(name.hasPrefix("@") && name.contains(":")),
              !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else { return nil }
        return name
    }
}

/// When a device was last active, as desktop `seenAgo` words it: minutes
/// within the hour, hours within the day, then days, in the app's language.
enum AccountDeviceSeen {
    static func ago(_ date: Date, now: Date = Date(), locale: String) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: locale)
        formatter.dateTimeStyle = .named
        formatter.unitsStyle = .full
        let minutes = Int((min(date, now).timeIntervalSince(now) / 60).rounded())
        if minutes > -60 { return formatter.localizedString(from: DateComponents(minute: minutes)) }
        let hours = Int((Double(minutes) / 60).rounded())
        if hours > -24 { return formatter.localizedString(from: DateComponents(hour: hours)) }
        return formatter.localizedString(from: DateComponents(day: Int((Double(hours) / 24).rounded())))
    }
}

/// Signing one device out, as desktop `endDeviceSession` does it: the sign-in
/// server's own page for ending that session (MSC4191
/// `org.matrix.device_delete`), opened in the browser, where the server signs
/// the person in if needed and asks them to confirm. The phone never ends a
/// session itself and holds no authority to; it only checks that the address
/// the SDK built is an HTTPS page for exactly that action and that device.
enum AccountDeviceSignOut {
    static let action = "org.matrix.device_delete"

    static func validatedURL(_ raw: String?, deviceID: String) -> URL? {
        guard let raw, let components = URLComponents(string: raw), components.scheme == "https",
              components.host?.isEmpty == false, components.user == nil, components.password == nil
        else { return nil }
        let items = components.queryItems ?? []
        guard items.contains(URLQueryItem(name: "action", value: action)),
              items.contains(URLQueryItem(name: "device_id", value: deviceID))
        else { return nil }
        return components.url
    }
}

/// Whether the account's recovery is on, for the recovery key row (desktop
/// `RecoveryRow`: "On", or "Not set up"). Unknown says nothing.
enum AccountRecoveryStatus: Equatable, Sendable {
    case unknown
    case on
    case off

    /// The SDK's recovery state, plus whether this phone holds the key. A
    /// backup this phone has not restored yet is still recovery that is on.
    init(recovery: MatrixLiveRecoveryStatus?, holdsRecoveryKey: Bool) {
        if holdsRecoveryKey { self = .on; return }
        switch recovery {
        case .ready?, .available?: self = .on
        case .unavailable?: self = .off
        case .unknown?, nil: self = .unknown
        }
    }
}

enum AccountDevicesFailure: Error { case invalid, refused }

extension LiveMatrixSession {
    /// `GET /_matrix/client/v3/devices`: the account's own sessions. The pinned
    /// SDK has no binding for it, so this one read goes to the session's own
    /// homeserver with the session's bearer (HTTPS only, no cookies, no
    /// redirects followed), as the company Activity read does.
    func ownDevicesJSON() async throws -> Data {
        try runtime.requireCurrent()
        let session = try runtime.client.session()
        guard var components = URLComponents(string: session.homeserverUrl), components.scheme == "https",
              components.host?.isEmpty == false else { throw AccountDevicesFailure.invalid }
        components.path = (components.path.hasSuffix("/") ? String(components.path.dropLast()) : components.path)
            + "/_matrix/client/v3/devices"
        guard let url = components.url else { throw AccountDevicesFailure.invalid }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.httpMethod = "GET"
        request.httpShouldHandleCookies = false
        request.setValue("Bearer " + session.accessToken, forHTTPHeaderField: "Authorization")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        let transport = URLSession(configuration: configuration, delegate: AccountDevicesNoRedirect(),
                                   delegateQueue: nil)
        defer { transport.finishTasksAndInvalidate() }
        let (data, response) = try await transport.data(for: request)
        try runtime.requireCurrent()
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw AccountDevicesFailure.refused }
        return data
    }

    /// This session's own device ID, to leave this phone out of the list.
    func ownDeviceID() throws -> String {
        try runtime.requireCurrent()
        return try runtime.client.deviceId()
    }

    /// The sign-in server's page for ending one session, from the SDK's
    /// account-management discovery. Nil when the server offers no such page.
    func deviceSignOutURL(deviceID: String) async throws -> URL? {
        try runtime.requireCurrent()
        let raw = try await runtime.client.accountUrl(action: .deviceDelete(deviceId: deviceID))
        try runtime.requireCurrent()
        return AccountDeviceSignOut.validatedURL(raw, deviceID: deviceID)
    }
}

private final class AccountDevicesNoRedirect: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest) async
        -> URLRequest? { nil }
}

extension LiveAppModel {
    /// Settings › Your devices: the account's other sessions. Nil when they
    /// cannot be read.
    func ownDevices() async -> [AccountDevice]? {
        guard let liveMatrix, let current = try? liveMatrix.ownDeviceID(),
              let data = try? await liveMatrix.ownDevicesJSON() else { return nil }
        return AccountDeviceList.parse(data, currentDeviceID: current)
    }

    /// The server's confirmation page for signing one device out. Never this
    /// phone's own session: that is Sign out.
    func deviceSignOutURL(deviceID: String) async -> URL? {
        guard let liveMatrix, let current = try? liveMatrix.ownDeviceID(), deviceID != current
        else { return nil }
        return try? await liveMatrix.deviceSignOutURL(deviceID: deviceID)
    }

    /// Whether the account's recovery is on, for the recovery key row.
    var accountRecoveryStatus: AccountRecoveryStatus {
        AccountRecoveryStatus(recovery: matrixRecoverySnapshot?.recovery, holdsRecoveryKey: holdsRecoveryKey)
    }
}
