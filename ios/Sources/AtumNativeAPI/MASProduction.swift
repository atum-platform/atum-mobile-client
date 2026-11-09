import Foundation

/// Public static clients deployed by the provider, 2026-10-07.
/// No credentials. Composition must still discover/verify MAS metadata and
/// bind both grant subjects to /me before publishing an account.
public enum MASProduction {
    public static let issuer = "https://auth.atumplatform.com/"
    public static let discoveryURL = URL(string: issuer + ".well-known/openid-configuration")!

    public static func clients() throws -> MASPublicClients {
        try MASPublicClients(matrix: "01M4AFFPZ5299GNAEJFKC5HAF8",
                             domain: "01M4AFFPZJKYKMRFVGWZ1GP3FJ")
    }

    public static func metadata(using transport: MASHTTP = MASHTTP()) async throws -> MASMetadata {
        try await transport.discovery(at: discoveryURL, expectedIssuer: issuer)
    }
}
