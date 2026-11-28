import AtumChat
import AtumNativeAPI
import Foundation

// ML3 (S1/S2) live hook for Home search. This is the only LiveAppModel
// surface the Home search UI adds: it reads existing model state and the
// existing SDK search sources (`personalMessageSearch`, `LocalSearchSource`,
// `confirmSearchTarget`) and composes no new engine. AppRoot passes the
// result to `HomeActions.messageSearch`; the coordinator owns its placement.

/// Home search's personal and device-only message sources for one live
/// Matrix session. Nil while there is no live session.
struct HomeMessageSearchActions {
    /// The live session these closures belong to. A different value replaces
    /// Home's search controller (account change, sign-out, restart).
    let session: ObjectIdentifier
    var personal: @MainActor (String, @escaping HomeSearchSources.IsCurrent) async throws
        -> PersonalMessageSearch.Page
    var personalRetained: @MainActor ([GlobalChatSearchHit]) -> [GlobalChatSearchHit]
    var companyRooms: @MainActor () -> Int
    var companyRetained: @MainActor ([CompanySearchResult]) -> [CompanySearchResult]
    var companyLabel: @MainActor (_ roomID: String, _ companyID: String?) -> String?
    var senderName: @MainActor (_ roomID: String, _ userID: String) async -> String?
    /// Built once per controller: the device source owns backfill and
    /// redaction subscriptions, so it must not be rebuilt on every render.
    /// Nil when this device cannot answer (old history unavailable) or
    /// holds no private chat to search.
    var makeDevice: @MainActor () -> HomeSearchSources.Device?
    /// Revalidates the hit (room, event, sender, thread) against the
    /// current scope, then routes to the exact event. False when the check or
    /// the route fails; the caller compares its generation before reporting.
    var open: @MainActor (HomeMessageHit, GlobalChatSearchScope, @escaping HomeSearchSources.IsCurrent) async -> Bool
}

extension LiveAppModel {
    /// `route` is AppRoot's room route with exact event placement.
    func homeMessageSearchActions(
        route: @escaping @MainActor (ChatSearchEventTarget, _ requiringCompany: String?) async -> Bool
    ) -> HomeMessageSearchActions? {
        guard let session = liveMatrix else { return nil }
        let id = ObjectIdentifier(session)
        let current: @MainActor () -> LiveMatrixSession? = { [weak self] in
            guard let live = self?.liveMatrix, ObjectIdentifier(live) == id else { return nil }
            return live
        }
        return HomeMessageSearchActions(
            session: id,
            personal: { [weak self] term, isCurrent in
                guard let self, let live = current() else { throw CancellationError() }
                let allowed = homePersonalSearchRoomIDs()
                return try await live.personalMessageSearch(allowsRoom: { allowed.contains($0) })
                    .search(term, isCurrent: isCurrent)
            },
            personalRetained: { [weak self] hits in
                guard let self, let live = current() else { return [] }
                let allowed = homePersonalSearchRoomIDs()
                return live.personalMessageSearch(allowsRoom: { allowed.contains($0) }).retained(hits)
            },
            companyRooms: { [weak self] in
                guard let self, let live = current() else { return 0 }
                let rows = Dictionary(live.rooms.map { ($0.roomID, $0) }, uniquingKeysWith: { first, _ in first })
                return Set(homeSearchTargets().values.flatMap { $0 }.map(\.roomID)).count {
                    rows[$0]?.isEncrypted == false
                }
            },
            companyRetained: { [weak self] results in
                guard let self, current() != nil else { return [] }
                return homeSearchEligibility().retained(results)
            },
            companyLabel: { [weak self] roomID, companyID in
                guard let self else { return nil }
                let company = companyID ?? homeSearchTargets().first { $0.value.contains { $0.roomID == roomID } }?.key
                return company.flatMap { companyWorkspace.companyName($0) }
            },
            senderName: { roomID, userID in
                await current()?.companyMemberName(roomID: roomID, userID: userID)
            },
            makeDevice: { [weak self] in
                guard let self, let live = current(), !live.runtime.oldHistoryUnavailable else { return nil }
                let source = LocalSearchSource(session: live, roomIDs: { [weak self] in
                    self?.homeDeviceSearchRoomIDs() ?? []
                })
                return HomeSearchSources.Device(
                    search: { term, isCurrent in try await source.search(term, isCurrent: isCurrent) },
                    retained: { source.retained($0) },
                    startBackfill: { source.startBackfill() },
                    stopBackfill: { source.stopBackfill() },
                    observeRedactions: { source.observeRedactions(for: $0, onChange: $1) },
                    stopObservingRedactions: { source.stopObservingRedactions() })
            },
            open: { [weak self] hit, scope, isCurrent in
                guard let self, let live = current() else { return false }
                switch hit.origin {
                case let .company(result):
                    // Desktop `openGlobalEvent`: the existing company check,
                    // then the company's own route, placed at the event.
                    return await HomeSearchRoute.open(
                        result, workspace: companyWorkspace,
                        confirm: { await self.openHomeSearchResult(result) },
                        route: { roomID, company in
                            await route(ChatSearchEventTarget(roomID: roomID, eventID: result.eventID,
                                                              threadRootID: result.threadRootID), company)
                        })
                case let .personal(found), let .device(found):
                    let visible = scope == .plain ? homePersonalSearchRoomIDs() : homeDeviceSearchRoomIDs()
                    guard let target = await live.confirmSearchTarget(
                        found, scope: scope, isVisible: { visible.contains($0) }, isCurrent: isCurrent),
                        isCurrent() else { return false }
                    return await route(target, nil)
                }
            })
    }

    /// The canonical Personal search gate (contract §3): rooms Home lists as
    /// real, openable chats (no invitation, placeholder, draft, catalog
    /// row or hidden room) that classify as personal. Company-bound rooms,
    /// private assistant working rooms and unsettled classifications fail
    /// closed. Independent of the list filter, the query and paging.
    func homePersonalSearchRoomIDs() -> Set<String> {
        guard liveMatrix != nil else { return [] }
        var allowed = Set<String>()
        for room in presentation().rooms.rooms where room.canOpen && !room.isInvitation && !room.isAwaitingRoom
            && !room.isComingSoon && !room.awaitsStart && room.id != MobileFounderPolicy.draftRowID {
            // `.personal` only: a settled personal room, or any room on an
            // account with no company capability (`personalChatRestoreClassification`).
            if companyWorkspace.personalChatRestoreClassification(room.id) == .personal {
                allowed.insert(room.id)
            }
        }
        return allowed
    }

    /// The device-only scope's rooms: the personal gate plus the company
    /// rooms the company search may name. Private assistant working rooms are
    /// bound separately and never listed here. `LocalSearchSource` itself
    /// keeps only joined rooms whose encryption is known.
    func homeDeviceSearchRoomIDs() -> Set<String> {
        homePersonalSearchRoomIDs().union(homeSearchTargets().values.flatMap { $0 }.map(\.roomID))
    }
}

extension HomeActions {
    /// Plain-scope sources from what Home already has. Live accounts add the
    /// personal provider, measured company coverage and the device index;
    /// scripted hosts keep their People, Messages and Files.
    @MainActor
    func searchSources() -> HomeSearchSources {
        var sources = HomeSearchSources()
        if let discovery = peopleDiscovery {
            sources.people = { await discovery.search($0) }
        }
        if let global = globalSearch {
            sources.company = global.search
            let eligibility = global.eligibility
            sources.companyRetained = { eligibility.retained($0) }
            let rooms = global.companyIDs.isEmpty ? 0 : global.channels.count
            sources.companyRooms = { rooms }
        }
        if let messages = messageSearch {
            sources.personal = messages.personal
            sources.personalRetained = messages.personalRetained
            if globalSearch != nil {
                sources.companyRooms = messages.companyRooms
                sources.companyRetained = messages.companyRetained
            }
            sources.companyLabel = messages.companyLabel
            sources.senderName = messages.senderName
            sources.device = messages.makeDevice()
        }
        return sources
    }

    /// What identifies the sources `searchSources()` builds: a change
    /// replaces Home's search controller.
    var searchKey: HomeSearchKey {
        HomeSearchKey(session: messageSearch?.session, people: peopleDiscovery != nil,
                      company: globalSearch != nil)
    }
}

struct HomeSearchKey: Hashable {
    let session: ObjectIdentifier?
    let people: Bool
    let company: Bool
}
