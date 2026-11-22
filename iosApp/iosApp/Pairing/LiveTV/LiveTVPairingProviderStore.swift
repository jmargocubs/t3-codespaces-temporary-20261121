import Foundation

extension LiveTVService {
    /// Stores a provider received through phone pairing. It goes through the same validated save
    /// path as a provider typed on the Apple TV, so the password lands in the existing keychain
    /// secret store and never in UserDefaults, and an invalid provider throws without saving.
    @discardableResult
    func savePairedProvider(_ payload: LiveTVPairingPayload) throws -> UUID {
        guard payload.isValid else { throw LiveTVError.invalidConfiguration }
        switch payload.kind {
        case .m3u:
            return try saveConfiguration(name: payload.name, playlistURL: payload.playlistURL ?? "",
                                         xmltvURL: payload.xmltvURL)
        case .xtream:
            return try saveXtreamConfiguration(name: payload.name, serverURL: payload.serverURL ?? "",
                                               username: payload.username ?? "", password: payload.password ?? "")
        }
    }
}
