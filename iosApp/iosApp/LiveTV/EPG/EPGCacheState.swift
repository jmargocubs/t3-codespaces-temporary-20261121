import Foundation

/// Small, independently replaceable retry metadata. It never contains HTTP validators or source
/// material; the fingerprint is the only source identity persisted here.
struct EPGCacheState: Codable, Equatable, Sendable {
    static let currentVersion = 1
    static let maximumFailureCount = 32
    static let maximumDate = 253_402_300_799.0 // 9999-12-31T23:59:59Z

    let version: Int
    let providerID: UUID
    let sourceFingerprint: Data
    /// Set once a verified v2 guide is linked. Unlinked state can bind a legacy v1 guide only.
    let contentID: UUID?
    let lastSuccessfulFetchAt: Double?
    let failureCount: Int
    let nextRetryAt: Double?

    init(providerID: UUID, sourceFingerprint: Data, contentID: UUID? = nil,
         lastSuccessfulFetchAt: Date? = nil, failureCount: Int = 0, nextRetryAt: Date? = nil) {
        version = Self.currentVersion
        self.providerID = providerID
        self.sourceFingerprint = sourceFingerprint
        self.contentID = contentID
        self.lastSuccessfulFetchAt = lastSuccessfulFetchAt?.timeIntervalSince1970
        self.failureCount = failureCount
        self.nextRetryAt = nextRetryAt?.timeIntervalSince1970
    }

    func isValid(for providerID: UUID, fingerprint: Data, associatedContentID: UUID? = nil) -> Bool {
        guard version == Self.currentVersion, self.providerID == providerID,
              sourceFingerprint.count == EPGSourceFingerprint.length,
              sourceFingerprint == fingerprint,
              contentID == associatedContentID,
              (0...Self.maximumFailureCount).contains(failureCount),
              validDate(lastSuccessfulFetchAt), validDate(nextRetryAt),
              (failureCount == 0) == (nextRetryAt == nil),
              contentID == nil || lastSuccessfulFetchAt != nil else { return false }
        return true
    }

    var lastSuccessfulFetchDate: Date? {
        lastSuccessfulFetchAt.map(Date.init(timeIntervalSince1970:))
    }

    var nextRetryDate: Date? {
        nextRetryAt.map(Date.init(timeIntervalSince1970:))
    }

    func linked(to contentID: UUID) -> EPGCacheState {
        EPGCacheState(providerID: providerID, sourceFingerprint: sourceFingerprint, contentID: contentID,
                      lastSuccessfulFetchAt: lastSuccessfulFetchDate, failureCount: failureCount,
                      nextRetryAt: nextRetryDate)
    }

    private func validDate(_ value: Double?) -> Bool {
        guard let value else { return true }
        return value.isFinite && value >= 0 && value <= Self.maximumDate
    }
}
