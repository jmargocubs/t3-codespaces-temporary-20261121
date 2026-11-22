# KyroMediaCore foundation

KyroMediaCore is an independent Swift package. It defines stable identities, profile-scoped operations, canonical media records, source parsing, playback contracts, and capability declarations without importing application modules.

The package uses system SQLite for durable state and Swift Crypto for cryptographic primitives. C1 provides one actor writer and a bounded pool of read-only actors (two by default, maximum eight). Each connection owns its private C handle synchronously, finalizes statements on every path, and closes on explicit close or destruction. SQLite runs in WAL mode with FULL synchronization and foreign keys enabled. Storage URLs are injected.

Transaction closures cannot suspend. Raw transaction/savepoint statements are denied by SQLite's authorizer; nested transactions are rejected. Cancellation observed before commit rolls back all changes. Cancellation racing after the last check may lose to commit, as with any cooperative cancellation boundary. Failed migrations roll back schema and version changes together; new versions must be consecutive. All diagnostic SQL errors contain numeric codes rather than potentially sensitive SQL or values.

Identifiers are domain-tagged UUIDs with stable Codable representations. Hybrid clocks use physical time, a logical counter, and a stable node tie-breaker. Wall-clock rollback advances logical time, untrusted future timestamps are rejected, and logical-counter exhaustion throws. Diagnostic URL redaction removes paths, queries and user information; all header values are redacted.

C1 host checks cover concurrent read/write access, persistence after reopen, migration failure recovery, WAL and FTS5, transaction commit/rollback and cancellation, explicit lifecycle errors, clock skew/overflow, identifier round trips, and forbidden app dependencies. Apple deployment targets are iOS 18, tvOS 26 and macOS 26. Apple validation is deferred by request; host tests do not establish Apple SDK compatibility.

Credential material is represented by a store protocol; no PIN derivation is implemented until a vetted password KDF has been selected and reviewed. Catalog, identity, ledger, sources, playback and capabilities remain scaffold work and are not acceptance-complete.
