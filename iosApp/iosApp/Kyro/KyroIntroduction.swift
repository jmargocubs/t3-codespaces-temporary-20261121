import Foundation

/// Kyro's three-page introduction, shown once per install to genuinely new
/// iPhone users before Silo's server setup.
///
/// It is local and separate from Silo's server-synced onboarding tour
/// (`OnboardingTourGate`), which runs per profile after sign-in. It sets
/// nothing up: Get Started and Skip both lead into the existing server
/// setup, and Live TV stays optional under the Live TV tab.
enum KyroIntroduction {
    static let completedDefaultsKey = "kyro.c3.introduction.completed"

    enum Symbol: Equatable {
        case clapperboard
        case television
        case layeredCards
    }

    struct Page: Identifiable, Equatable {
        let id: Int
        let headline: String
        let message: String
        let symbol: Symbol
        let symbolLabel: String
    }

    static let pages: [Page] = [
        Page(
            id: 0,
            headline: "Your Media,\nAll in One Place",
            message: "Your personal movie and TV library, beautifully organized.",
            symbol: .clapperboard,
            symbolLabel: "Clapperboard"
        ),
        Page(
            id: 1,
            headline: "Live TV",
            message: "Stream your favorite channels with a beautiful, modern experience.",
            symbol: .television,
            symbolLabel: "Television"
        ),
        Page(
            id: 2,
            headline: "Your Entertainment,\nYour Way",
            message: "A premium, customizable streaming experience for your movies, shows, Live TV, and more.",
            symbol: .layeredCards,
            symbolLabel: "Movies, television and customization cards"
        ),
    ]

    /// Genuinely new means the first route this launch resolved to is server
    /// setup with no saved server. Anyone with a saved server, a session or a
    /// profile is an existing user and goes straight on.
    static func shouldPresent(
        initialState: AppRouter.AuthState,
        hasSavedServers: Bool,
        isCompleted: Bool,
        isEligibleDevice: Bool
    ) -> Bool {
        guard isEligibleDevice, !isCompleted, !hasSavedServers else { return false }
        return initialState == .needsServerSetup
    }

    /// Decides at the first committed route of a launch. An existing user is
    /// recorded as done, so the introduction never appears later just
    /// because they removed every server.
    static func resolveAtLaunch(
        initialState: AppRouter.AuthState,
        hasSavedServers: Bool,
        isEligibleDevice: Bool,
        defaults: UserDefaults = .standard
    ) -> Bool {
        let isCompleted = defaults.bool(forKey: completedDefaultsKey)
        let present = shouldPresent(
            initialState: initialState,
            hasSavedServers: hasSavedServers,
            isCompleted: isCompleted,
            isEligibleDevice: isEligibleDevice
        )
        if isEligibleDevice, !present, !isCompleted {
            defaults.set(true, forKey: completedDefaultsKey)
        }
        return present
    }

    static func markCompleted(defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: completedDefaultsKey)
    }
}
