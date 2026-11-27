import AtumNativeAPI
import MatrixRustSDK

enum PrivatePeopleChat {
    static func people(_ lookups: [AliasLookupResponse], ownUserID: String) throws -> [NativeMatrixUser] {
        let targets = lookups.compactMap(\.humanMessageTarget)
        guard targets.count == lookups.count else { throw MatrixSecurityFailure.notHuman }
        guard targets.allSatisfy({ $0.rawValue != ownUserID }),
              Set(targets).count == targets.count else {
            throw MatrixSecurityFailure.invalidParticipants
        }
        return targets
    }

    static func parameters(name: String?, isDirect: Bool, targets: [NativeMatrixUser],
                           encrypted: Bool = false) -> CreateRoomParameters {
        CreateRoomParameters(
            name: name,
            isEncrypted: encrypted,
            isDirect: isDirect,
            visibility: .private,
            preset: .privateChat,
            invite: targets.map(\.rawValue),
            historyVisibilityOverride: encrypted ? .joined : .shared
        )
    }
}
