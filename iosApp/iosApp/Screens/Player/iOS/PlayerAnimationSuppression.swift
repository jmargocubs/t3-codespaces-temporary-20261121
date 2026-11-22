import Foundation

/// Build 70: the ledger behind the player's unanimated rotations.
///
/// Build 51 turned UIKit animations off for the rotation the player requested and, when that
/// rotation's transition completed, restored the value it had read just before. A second
/// suppressed rotation that began before the first completed (full screen, then Picture in Picture
/// or Close straight away), or a rotation that began inside a `performWithoutAnimation` block, read
/// `false` and restored `false` last. UIKit animations then stayed off for the whole process until
/// relaunch. Every sheet presented, resized and dismissed in a single frame (Build 69 recording
/// 11-13 23:19, after a full-screen Picture in Picture test).
///
/// Each suppression now holds a token. Animations come back when the last outstanding token ends,
/// whatever order the completions arrive in, and a token that is never ended expires at its
/// deadline, so a lost completion cannot leave them off either.
struct PlayerAnimationSuppression: Equatable {
    /// Longer than any rotation transition. A suppressed rotation has no animation and completes in
    /// a frame or two; this only matters when UIKit never reports the completion.
    static let deadline: TimeInterval = 2

    private(set) var outstanding: Set<Int> = []
    private var lastToken = 0

    var isSuppressing: Bool { !outstanding.isEmpty }

    /// A suppressed rotation is starting. Turn animations off and end the returned token when its
    /// transition completes (or at `deadline`).
    mutating func begin() -> Int {
        lastToken += 1
        outstanding.insert(lastToken)
        return lastToken
    }

    /// True when this ended the last outstanding suppression, so animations must come back on.
    /// Ending a token twice (completion, then deadline) or one never issued does nothing.
    mutating func end(_ token: Int) -> Bool {
        guard outstanding.remove(token) != nil else { return false }
        return outstanding.isEmpty
    }
}
