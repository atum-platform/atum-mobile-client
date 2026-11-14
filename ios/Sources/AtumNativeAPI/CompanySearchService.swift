import Foundation

// Home search's company fan-out (desktop `searchCompanies`) with everything it
// touches injected: the rooms each company lists, the current eligibility, the
// `from:` member reads and the `/search` transport. The app supplies the live
// ones; tests supply fakes. No authority lives here: every room is checked
// against the caller's current eligibility when the job is queued, when it gets
// its slot, after its member reads, and when its answer arrives.

/// Where one `/search` goes: the session's own homeserver with its bearer.
/// `stillCurrent` throws once the session it came from is gone.
public struct CompanySearchEndpoint: Sendable {
    public let url: URL
    public let bearer: String
    public let stillCurrent: @Sendable @MainActor () throws -> Void

    public init(url: URL, bearer: String, stillCurrent: @escaping @Sendable @MainActor () throws -> Void) {
        self.url = url
        self.bearer = bearer
        self.stillCurrent = stillCurrent
    }
}

/// Sends one `POST /_matrix/client/v3/search`. One instance (one URL session)
/// serves every Home search request.
@MainActor
public protocol CompanySearchTransport: AnyObject {
    func search(body: Data, endpoint: CompanySearchEndpoint) async throws -> Data
}

/// `from:@name` over a room's members, every membership (desktop
/// `room.getMembers()`: a former member still wrote their old messages). It
/// reads the whole member list in bounded chunks and matches as it goes; only
/// the number of matches is capped, never the number of members read.
public enum CompanySearchMemberReader {
    public static let chunkSize: UInt32 = 200
    /// More matches than this for one name is no longer a name.
    public static let maximumMatches = 500

    /// `next` hands out the next chunk; nil or empty ends the list.
    public static func senders(from: String, next: () -> [CompanySearchMember]?) -> [String] {
        var matches = Set<String>()
        while matches.count < maximumMatches, !Task.isCancelled, let chunk = next(), !chunk.isEmpty {
            for member in chunk where CompanyMessageSearch.memberMatches(userID: member.userID,
                                                                         names: member.names, from: from) {
                matches.insert(member.userID)
                if matches.count == maximumMatches { break }
            }
        }
        return matches.filter(CompanyMessageSearch.isUserID).sorted()
    }
}

@MainActor
public final class CompanySearchService {
    /// What one search reads from the live session, at the moment it reads it.
    public struct Environment {
        /// Each company's directory-listed rooms.
        public var targets: @MainActor () -> [String: [CompanySearchTarget]]
        /// The rooms that may be read and shown now.
        public var eligibility: @MainActor () -> CompanySearchEligibility
        public var ownUserID: @MainActor () -> String?
        /// `from:@name`'s matches among one room's members (any membership).
        public var senders: @MainActor (_ roomID: String, _ from: String) async -> [String]
        public var endpoint: @MainActor () throws -> CompanySearchEndpoint

        public init(targets: @escaping @MainActor () -> [String: [CompanySearchTarget]],
                    eligibility: @escaping @MainActor () -> CompanySearchEligibility,
                    ownUserID: @escaping @MainActor () -> String?,
                    senders: @escaping @MainActor (_ roomID: String, _ from: String) async -> [String],
                    endpoint: @escaping @MainActor () throws -> CompanySearchEndpoint) {
            self.targets = targets
            self.eligibility = eligibility
            self.ownUserID = ownUserID
            self.senders = senders
            self.endpoint = endpoint
        }
    }

    /// Shared by both tabs: at most `limit` company searches at once.
    public let limiter: CompanySearchLimiter
    /// Shared by both tabs: one session for every request.
    public let transport: CompanySearchTransport

    public init(makeLimiter: () -> CompanySearchLimiter, makeTransport: () -> CompanySearchTransport) {
        limiter = makeLimiter()
        transport = makeTransport()
    }

    /// Desktop `searchCompanies`: ten of one tab from every company, companies
    /// in id order. A company that fails answers nothing (no error row, no
    /// retry). Work waits in the shared queue; nothing new is scheduled once the
    /// search is cancelled, and a waiting job never starts after cancellation.
    public func search(_ term: String, tab: CompanySearchTab, environment: Environment) async -> [CompanySearchResult] {
        guard let query = CompanyMessageSearch.query(term) else { return [] }
        let eligibility = environment.eligibility()
        var tasks = [(String, Task<[CompanySearchResult], Never>)]()
        for (company, targets) in environment.targets().sorted(by: { $0.key < $1.key }) {
            if Task.isCancelled { break }
            let admitted = CompanyMessageSearch.admitted(targets, query: query, companyID: company,
                                                         eligibility: eligibility)
            guard !admitted.isEmpty else { continue }
            tasks.append((company, Task { @MainActor in
                await self.limiter.run {
                    await self.page(companyID: company, admitted: admitted, query: query, tab: tab,
                                    environment: environment)
                } ?? []
            }))
        }
        var pages = [String: [CompanySearchResult]]()
        await withTaskCancellationHandler {
            for entry in tasks { pages[entry.0] = await entry.1.value }
        } onCancel: {
            for entry in tasks { entry.1.cancel() }
        }
        return CompanyMessageSearch.merged(pages)
    }

    private func page(companyID: String, admitted: [CompanySearchTarget], query: CompanySearchQuery,
                      tab: CompanySearchTab, environment: Environment) async -> [CompanySearchResult] {
        // An operator-only query (`from:me`) is answered from the loaded
        // timeline on desktop; the phone has no such read yet.
        guard !query.needsLoadedHistory else { return [] }
        // The queue may have held this job while a room was left or encrypted.
        var rooms = Self.stillEligible(admitted, companyID: companyID, environment.eligibility())
        guard !rooms.isEmpty else { return [] }
        var senders: [String]?
        if let from = query.from {
            if from == "me" {
                senders = environment.ownUserID().map { [$0] } ?? []
            } else {
                var found = Set<String>()
                for room in rooms {
                    if Task.isCancelled { return [] }
                    found.formUnion(await environment.senders(room.roomID, from))
                }
                senders = found.filter(CompanyMessageSearch.isUserID).sorted()
                // The member reads were async too.
                rooms = Self.stillEligible(rooms, companyID: companyID, environment.eligibility())
            }
        }
        guard senders?.isEmpty != true, !rooms.isEmpty, !Task.isCancelled,
              let body = try? CompanyMessageSearch.requestBody(query: query, tab: tab,
                                                                roomIDs: rooms.map(\.roomID), senders: senders),
              let endpoint = try? environment.endpoint(),
              let data = try? await transport.search(body: body, endpoint: endpoint),
              let found = CompanyMessageSearch.results(responseJSON: data, companyID: companyID, tab: tab,
                                                       query: query, targets: rooms) else { return [] }
        // Asked for the rooms eligible then; shown only for the rooms eligible now.
        return environment.eligibility().retained(found)
    }

    private static func stillEligible(_ rooms: [CompanySearchTarget], companyID: String,
                                      _ eligibility: CompanySearchEligibility) -> [CompanySearchTarget] {
        rooms.filter { eligibility.allows(companyID: companyID, channelID: $0.channelID, roomID: $0.roomID) }
    }
}
