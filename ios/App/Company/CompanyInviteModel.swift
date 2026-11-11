import AtumNativeAPI
import Foundation

// Wave 3 TS-11 (invite people, invite links, join with a link) and TS-13
// (create a channel, the channel sections) on the company model. Every call
// names the company it was drawn for and is dropped when the account scope
// moved on while it ran. The platform stays decisive: a refused call says so,
// and a control the profile or the viewer's role says cannot work is not drawn.
// Desktop references: docs/ports/w3-team-space.md.

/// How one channel create ended. `roomID` is the new channel's room once the
/// platform has made it; nil while it is still being prepared (the list says so).
enum CompanyChannelCreateResult: Equatable {
    case created(roomID: String?)
    case failed(CompanyAPIError?)
}

/// What a create-link press came to, for the links section.
enum CompanyInviteLinkCreateResult: Equatable {
    case created(CompanyInviteLinkSecret)
    /// The link exists but its text was lost with an earlier answer (shown once).
    case replayed(NativeID)
    case failed(CompanyAPIError?)
}

struct CompanyInviteRevokeFailure: Equatable {
    let error: CompanyAPIError?
}

extension CompanyWorkspaceModel {
    private func invitesClient() -> CompanyInvitesAPI? { invitesProvider() }

    /// The server's team-space profile; the legacy one until a probe said more.
    var teamSpaceProfile: CompanyTeamSpaceProfile { .resolve(conversations.capabilities) }

    /// The viewer's own role in a company, nil until its snapshot was read.
    func viewerIsAdmin(companyID: String) -> Bool? {
        guard let snapshot = snapshotsByCompany[companyID] else { return nil }
        return snapshot.members.first(where: \.isSelf)?.role == .admin
    }

    func inviteAbilities(companyID: String?) -> CompanyInviteAbilities {
        guard let companyID, invitesClient() != nil else { return .none }
        return .resolve(profile: teamSpaceProfile, viewerIsAdmin: viewerIsAdmin(companyID: companyID),
                        readiness: inviteReadiness)
    }

    func channelCreationAllowed(companyID: String?) -> Bool {
        guard let companyID, invitesClient() != nil else { return false }
        return CompanyChannelCreation.allowed(profile: teamSpaceProfile,
                                              viewerIsAdmin: viewerIsAdmin(companyID: companyID))
    }

    /// Where a typed handle already stands with this company.
    func inviteStanding(companyID: String, handle: String?) -> CompanyInviteStanding {
        .resolve(handle: handle, members: snapshotsByCompany[companyID]?.members ?? [])
    }

    /// The channel rooms the person has marked as favourites (Matrix `m.favourite`).
    func favouriteChannelRooms(from rooms: [LiveProductRoom]) -> Set<String> {
        Set(rooms.filter { $0.isPinned && !$0.isInvitation && isCompanyChannel($0.id) }.map(\.id))
    }

    /// Readiness is asked only where it can widen something: team admin on.
    func readInviteReadiness(scope: UInt64) async {
        guard teamSpaceProfile.admin, let client = invitesClient() else {
            inviteReadiness = nil
            return
        }
        let epoch = inviteEpoch
        do {
            let readiness = try await client.companyInviteReadiness()
            guard scope == generation, epoch == inviteEpoch else { return }
            inviteReadiness = readiness
        } catch {
            // An older install answers 400/404 to the profile header: keep today's methods.
            guard scope == generation, epoch == inviteEpoch else { return }
            inviteReadiness = nil
        }
    }

    // MARK: Invite people

    func invite(companyID: String, handle: String) async -> CompanyInviteOutcome {
        let abilities = inviteAbilities(companyID: companyID)
        guard abilities.invite, let client = invitesClient(), let id = try? NativeID(companyID),
              let request = try? NativeID(UUID().uuidString.lowercased()) else {
            return .refused(.denied, reason: nil)
        }
        let epoch = inviteEpoch
        do {
            try await client.inviteToCompany(companyID: id, requestID: request, handle: handle,
                                             method: abilities.method)
        } catch let error as CompanyAPIError {
            guard epoch == inviteEpoch else { return .unavailable }
            switch error {
            case let .refused(refusal, reason, _): return .refused(refusal, reason: reason)
            case .transport, .unavailable, .invalid: return .unavailable
            }
        } catch {
            return .unavailable
        }
        guard epoch == inviteEpoch else { return .unavailable }
        // The roster now lists them as invited.
        await refreshCompany(companyID)
        return .invited
    }

    // MARK: Invite links

    /// The company's links that still work; nil when they could not be read.
    func inviteLinks(companyID: String) async -> [CompanyInviteLinkSummary]? {
        guard inviteAbilities(companyID: companyID).inviteLink, let client = invitesClient(),
              let id = try? NativeID(companyID) else { return nil }
        let epoch = inviteEpoch
        guard let links = try? await client.companyInviteLinks(companyID: id), epoch == inviteEpoch else {
            return nil
        }
        return links.filter { $0.state == .active }
    }

    func createInviteLink(companyID: String) async -> CompanyInviteLinkCreateResult {
        guard inviteAbilities(companyID: companyID).inviteLink, let client = invitesClient(),
              let id = try? NativeID(companyID),
              let request = try? NativeID(UUID().uuidString.lowercased()) else { return .failed(nil) }
        let epoch = inviteEpoch
        do {
            let created = try await client.createCompanyInviteLink(companyID: id, requestID: request)
            guard epoch == inviteEpoch else { return .failed(nil) }
            switch created {
            case let .created(secret): return .created(secret)
            case let .replayed(summary): return .replayed(summary.id)
            }
        } catch {
            return .failed(error as? CompanyAPIError)
        }
    }

    /// Nil when the link was revoked, else why not.
    func revokeInviteLink(companyID: String, linkID: NativeID) async -> CompanyInviteRevokeFailure? {
        guard inviteAbilities(companyID: companyID).revokeInviteLink, let client = invitesClient(),
              let id = try? NativeID(companyID),
              let request = try? NativeID(UUID().uuidString.lowercased()) else { return .init(error: nil) }
        do {
            try await client.revokeCompanyInviteLink(companyID: id, linkID: linkID, requestID: request)
            return nil
        } catch {
            return .init(error: error as? CompanyAPIError)
        }
    }

    // MARK: Join with an invite link

    func previewInviteLink(_ token: CompanyInviteLinkToken) async -> CompanyInviteJoinState {
        guard let client = invitesClient() else { return .failure(.unavailable, preview: nil) }
        do {
            let preview = try await client.previewCompanyInviteLink(token: token)
            return CompanyInviteJoin.previewed(preview, now: Int64(Date().timeIntervalSince1970))
        } catch {
            return CompanyInviteJoin.previewFailed(error)
        }
    }

    /// Redeems the link with the flow's own request ID (a retry replays it), then
    /// reads the companies again and opens the one joined.
    func redeemInviteLink(_ token: CompanyInviteLinkToken, requestID: NativeID,
                          preview: CompanyInviteLinkPreview) async -> CompanyInviteJoinState {
        guard let client = invitesClient() else { return .failure(.unavailable, preview: preview) }
        let epoch = inviteEpoch
        let state: CompanyInviteJoinState
        do {
            let redeemed = try await client.redeemCompanyInviteLink(requestID: requestID, token: token)
            guard redeemed.companyId == preview.companyId else { return .failure(.unavailable, preview: preview) }
            state = CompanyInviteJoin.redeemed(redeemed, preview: preview)
        } catch {
            return CompanyInviteJoin.redeemFailed(error, preview: preview, now: Int64(Date().timeIntervalSince1970))
        }
        guard epoch == inviteEpoch else { return .failure(.unavailable, preview: preview) }
        await refresh()
        if case let .complete(_, _, companyID) = state { selectCompany(companyID) }
        return state
    }

    // MARK: Create a channel (TS-13)

    func createChannel(companyID: String, named typed: String) async -> CompanyChannelCreateResult {
        guard channelCreationAllowed(companyID: companyID), let client = invitesClient(),
              let id = try? NativeID(companyID), let name = CompanyChannelName.normalized(typed) else {
            return .failed(nil)
        }
        let key = companyID + "\n" + name
        let requestRaw = channelCreateRequests[key] ?? UUID().uuidString.lowercased()
        channelCreateRequests[key] = requestRaw
        guard let request = try? NativeID(requestRaw) else { return .failed(nil) }
        let epoch = inviteEpoch
        do {
            let entry = try await client.createCompanyChannel(companyID: id, requestID: request, displayName: name)
            guard epoch == inviteEpoch else { return .failed(nil) }
            channelCreateRequests.removeValue(forKey: key)
            await refreshCompany(companyID)
            return .created(roomID: entry.room.state == "ready" ? entry.room.roomId : nil)
        } catch let error as CompanyAPIError {
            guard epoch == inviteEpoch else { return .failed(nil) }
            // A refusal is final for that request; a lost answer keeps it for a replay.
            if case .refused = error { channelCreateRequests.removeValue(forKey: key) }
            return .failed(error)
        } catch {
            return .failed(nil)
        }
    }
}
