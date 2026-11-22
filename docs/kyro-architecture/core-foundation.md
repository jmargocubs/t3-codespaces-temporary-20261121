# KyroMediaCore foundation

KyroMediaCore is an independent Swift package. It defines stable identities, profile-scoped operations, canonical media records, source parsing, playback contracts, and capability declarations without importing application modules.

The package uses system SQLite for durable state and Swift Crypto for cryptographic primitives. C1 provides one actor writer and a bounded pool of read-only actors (two by default, maximum eight). Each connection owns its private C handle synchronously, finalizes statements on every path, and closes on explicit close or destruction. SQLite runs in WAL mode with FULL synchronization and foreign keys enabled. Storage URLs are injected.

Transaction closures cannot suspend. Raw transaction/savepoint statements are denied by SQLite's authorizer; nested transactions are rejected. Cancellation observed before commit rolls back all changes. Cancellation racing after the last check may lose to commit, as with any cooperative cancellation boundary. Failed migrations roll back schema and version changes together; new versions must be consecutive. All diagnostic SQL errors contain numeric codes rather than potentially sensitive SQL or values.

Identifiers are domain-tagged UUIDs with stable Codable representations. Hybrid clocks use physical time, a logical counter, and a stable node tie-breaker. Wall-clock rollback advances logical time, untrusted future timestamps are rejected, and logical-counter exhaustion throws. Diagnostic URL redaction removes paths, queries and user information; all header values are redacted.

C1 host checks cover concurrent read/write access, persistence after reopen, migration failure recovery, WAL and FTS5, transaction commit/rollback and cancellation, explicit lifecycle errors, clock skew/overflow, identifier round trips, and forbidden app dependencies. HybridClock serializes concurrent device ticks. Apple deployment targets are iOS 18, tvOS 26 and macOS 26.

C2 profiles, tombstones, provider registry, grants and PIN records persist in SQLite. Provider secrets remain behind CredentialStore; the memory implementation is explicitly for tests. PIN protection uses the official Argon2 reference release 20190702 (commit 62358ba2123abd17fccf2a108a301d4b52c01a7c), retained unchanged under its upstream license. Argon2id v19 uses 19 MiB, two passes, one lane, a random 16-byte salt, and a 32-byte result. Upstream verification handles constant-time comparison. A known upstream vector and salt/verification tests run on the host. Stored work factors are bounded before verification. Five failed attempts block verification for 60 seconds; a PIN is not database encryption and cannot overcome its low entropy against an offline attacker. The reference C implementation is portable; Apple SDK verification remains pending.

C3 stores profile-scoped immutable operations in SQLite. Merge is set union; registers select a total order of clock, operation ID and canonical payload. Collection removes retain the specific add tags observed, so concurrent adds survive. The suite checks 1,000 seeded merge permutations, associative/commutative/idempotent properties, profile isolation, persisted history and Continue Watching behavior.

## Catalog and source contracts

C4 represents movies, series, seasons and episodes, parent relationships, external identifiers, versions, editions and field provenance. Source partitions belong to an account and library. Portable keys use a versioned namespace and escaped identifier; provider-local IDs include account scope in adapters. Canonical aliases and explicit merge/separate overrides are persisted. Automatic matching requires a shared external ID and rejects conflicting IDs, years, kinds and editions. Title normalization removes common IPTV resolution/codec noise but never supplies sufficient merge evidence by itself.

Catalog imports write staging generations. Promotion checks the expected item count and changes the active pointer in one SQLite transaction. Failed or canceled imports preserve the prior pointer; SyncCoordinator removes failed staging data in an uncanceled cleanup task. Readers search only active generations. Keyset cursors contain generation, title and ID; a cursor from a replaced generation fails explicitly. Old published generations are retained for now; retention and garbage collection are a later operational concern. FTS5 indexes title text with partition/generation filtering.

C5 includes Jellyfin movie Items/ProviderIds/MediaSources and Xtream VOD list/get_vod_info parsing and adapters. All tests use synthetic fixtures and injected transports; no production requests or credentials are used. The HTTP actor owns per-account token buckets and breakers, permits at most two active transports globally, retries transient failures with capped exponential jitter and Retry-After delays, and supports cooperative cancellation/deadlines. Injected transports must honor cancellation. URLSession transport uses ephemeral storage, default TLS verification and an origin-preserving redirect policy. Errors retain status/numeric transport codes instead of credential-bearing URLs. HTTP endpoints remain supported for providers that require them; app integration must make that transport choice explicit.

C6 defines engine-independent intents, resolved streams and sessions, playback reporting events, quality and provenance, and profile-scoped capability providers. Unknown quality stays unknown; it is not inferred from a title. Resolved transport URLs and headers are ephemeral and deliberately not Codable. Diagnostic descriptions redact them. Capability states distinguish unsupported, authentication, grant, reachability and unknown conditions.

## Validation and checkpoint history

Run `swift test --package-path Packages/KyroMediaCore -j 2` from the worktree root. All eleven modules have host test targets; KyroMediaCoreTests holds the cross-module acceptance suite. The host is Swift 6.4.3 on Ubuntu 24.04 with system SQLite 3.45.1. Swift Crypto is pinned at 3.15.1; Swift ASN.1 is locked transitively. The unused SQLite.swift scaffold dependency was removed; SQLite uses the CSQLite system-library shim on Linux and Apple SDKs.

The acceptance suite contains 320 labeled synthetic matching pairs (80 eligible positives, 240 negatives), 1,000 seeded ledger merge permutations, and 50,000-title forward and reverse pagination. These are synthetic coverage, not a claim about production metadata accuracy. The host suite has 45 tests across twelve targets. A measured run took 12.912 seconds of summed XCTest suite time; the 50,000-title import/pagination test took 6.874 seconds, with zero matching false merges and 80/80 eligible recall.

| Acceptance | Evidence | Host result |
| --- | --- | --- |
| C-1 independent compilation | Swift 6 package build; automated forbidden dependency scan | PASS |
| C-2 profiles, PINs, tombstones | reopen, Argon2 reference vector, salt uniqueness, PIN verification, persisted lockout, deletion | PASS |
| C-3 ledger merge | 1,000 permutations plus commutative, associative and idempotent checks | PASS |
| C-4 Continue Watching | active/completed/watched states and profile isolation | PASS |
| C-5 writable subjects | concurrent grant attempts produce one owner | PASS |
| C-6 matching accuracy | 320 synthetic labeled pairs; zero false merges; 100% eligible shared-ID recall | PASS |
| C-7 pagination | 50,000 unique items, forward/reverse equality and title tie-breaks | PASS |
| C-8 provider fixtures | Jellyfin and Xtream parsing and request construction | PASS |
| C-9 HTTP resilience | buckets, retries/jitter, breaker, concurrency, timeout and cancellation | PASS |
| C-10 catalog promotion | failed/canceled generation and sync imports keep prior active data | PASS |
| C-11 portable identifiers | golden external key, editions, aliases and account-local separation | PASS |

Local milestone commits preserve the Labs-based development history: C1 `d9d730b7`, C2 `5289318d`, C3 `0e89157c`, C4 `07fac6fe`, C5 `54f364e2`, and C6 `c99b9497`. Subsequent review commits complete module boundaries, validation and documentation. The private backup has independent history containing only this package, this document and its workflow; it does not contain Labs ancestry.

The existing private macOS workflow passed on foundation commit `44a9be9`, with 30 tests passing on Apple Swift 6.3.3: https://github.com/jmargocubs/t3-codespaces-temporary-20261121/actions/runs/44980977920 . Later pushes rerun the same workflow; use the latest run for the current branch. The private repository's main branch and Codespaces configuration are preserved.

## Integration boundary

Phase 0/1 ends at these independent APIs. No app integration, playback engine, UI, IPA, signing, public push or Labs merge is included. Before integration, validate iOS/tvOS SDK compilation and physical-device behavior, supply an Apple Keychain CredentialStore, review privacy/backup retention and benchmark PIN costs on target devices. The test credential store is intentionally in memory; durable provider secrets must not use the catalog/identity document store. Provider compatibility beyond synthetic fixtures and real-player reporting remain integration work. No server or Android changes are required for this standalone package.
