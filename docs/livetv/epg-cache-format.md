# Live TV guide cache format

Status: version 2 is frozen for Phase 3C Milestone 2A. Change the layout only by adding a new
version. Implementation: `iosApp/iosApp/LiveTV/EPG/EPGCacheFormat.swift`. Tests:
`iosApp/Tests/EPGCacheFormatTests.swift`.

Each provider has one guide file. The file holds programme listings and a keyed source
fingerprint. It never contains feed URLs, usernames, passwords, or tokens.

## Version 2 layout

All integers are unsigned and big-endian unless noted.

| Offset | Size | Field | Rule |
|---|---|---|---|
| 0 | 4 | Magic | `KEPG` |
| 4 | 1 | Version | `2` |
| 5 | 3 | Reserved | All zero |
| 8 | 4 | Header length | Exactly `156` |
| 12 | 16 | Provider ID | UUID bytes; must match the requested provider |
| 28 | 16 | Content ID | Random UUID per write; links the guide to its state file |
| 44 | 32 | Source fingerprint | HMAC-SHA256 of the source identity under the per-device key (`EPGSourceIdentity`) |
| 76 | 8 | `fetchedAt` | IEEE 754 double, seconds since 1970; finite, 0 through year 9999 |
| 84 | 8 | Coverage start | Signed whole seconds since 1970 |
| 92 | 8 | Coverage end | Signed whole seconds since 1970; greater than the start |
| 100 | 4 | Programme count | At most 200,000 |
| 104 | 4 | Channel count | At most the programme count; zero only if no programmes |
| 108 | 8 | Compressed length | Greater than zero; equals file size minus 156 |
| 116 | 8 | Decompressed length | Greater than zero; at most 64 MiB |
| 124 | 32 | Payload digest | SHA-256 of bytes 156 through the end of the file |
| 156 | n | Payload | One LZFSE stream of the JSON record, with no trailing bytes |

With no programmes, both coverage fields are `0`. The whole file is at most 48 MiB.

The digest detects accidental corruption. It does not authenticate the file: anyone who can
rewrite the payload can also rewrite the digest.

## Read order

1. Check the file size against 48 MiB. Then check the magic, version, reserved bytes, and header
   length.
2. Validate every header field against the rules above. The header can be read alone, from the
   first 156 bytes and the file size, without decompressing anything.
3. Check that the provider ID matches.
4. Hash the payload and compare the result with the stored digest before decompressing.
5. Walk the LZFSE block headers without decoding (see [LZFSE block walk](#lzfse-block-walk)). The
   end-of-stream block must end exactly at the end of the file. The blocks' raw sizes must add up
   to the declared length. This step is required because Apple's stream decoder reports the end
   of the stream but silently consumes any bytes after it, so it can't detect trailing or
   concatenated data.
6. Allocate a buffer of exactly the declared length and decompress into it with Apple's
   Compression streaming API. Each call offers the decoder only the remaining allowance plus one
   probe byte. A chunk that would pass the limit is rejected and never appended. Require exactly
   the declared length.
7. Decode the JSON record and validate it (next section). Release the decompressed buffer, then
   build the index.
8. Check that the record's programme count, channel count, coverage, and `fetchedAt` match the
   header.

A failure at any step rejects the file. Cache decoding never checks for task cancellation, so a
cancelled caller can't make a valid file look corrupt.

## JSON record

The record is shared with version 1:
`{fetchedAt, channelIDs, names, rows: [{c, s, d, t, st?, ds?, g?, e?}]}`.

A record is rejected if any of these fail:

- The row count is within the programme limit.
- Channel IDs are unique, are at most 4,096 UTF-8 bytes, and no ID is blank.
- There are at most 200,000 name entries. Each key and value is at most 4,096 UTF-8 bytes.
- Every row's channel index is in range, its duration is positive, and its start and end fall
  between 1970 and year 9999.
- Each text field is at most 600 characters.
- Each channel's programmes are in airing order and do not overlap.

The encoder applies the same checks. It never writes a file that the reader would reject.

Version 1 applies only the structural checks: fetch time, channel index, positive duration,
start and end between 1970 and year 9999 (with overflow-checked addition), non-blank channel IDs,
and airing order. The count, uniqueness, identifier and text limits are version 2 policy, which
the Milestone 1 writer never applied. A legacy cache must not be deleted because it fails them.

## LZFSE block walk

Block layouts follow the LZFSE reference implementation, `src/lzfse_internal.h` at
lzfse/lzfse@e634ca58. All fields are little-endian.

| Magic | Block | Length |
|---|---|---|
| `bvx$` | End of stream | 4 |
| `bvx-` | Stored | 8 + raw size (offset 4) |
| `bvxn` | LZVN | 12 + payload size (offset 8) |
| `bvx1` | LZFSE, plain tables | 772 + literal payload (offset 20) + match payload (offset 24) |
| `bvx2` | LZFSE, packed tables | header size (bits 0–31 of the third packed field, at least 32) + literal payload (bits 20–39 of the first) + match payload (bits 40–59 of the second) |

Every block's raw size is at offset 4. Any other magic, or a block that would run past the
payload, rejects the file. The `bvx1` header is the reference decoder's unpacked C struct, read
with `sizeof`. Its fields total 770 bytes, and alignment padding makes it 772 on every Apple
target. The reference encoder always writes `bvx2`, so `bvx1` appears only from other encoders.
The test fixture is the reference encoder's output, rewritten with the reference header
conversion and checked with the reference decoder. Apple's decoder decodes it to the same bytes.

## Store behaviour

- A failed or oversized write leaves the previous file untouched. The write is atomic. Every record
  check runs before a stage file exists; the payload is then streamed into the stage, reopened,
  fully decoded and compared with the guide and header written, and only an exact match is
  promoted.
- The v2 writer streams the payload. A `JSONEncoder` with sorted keys encodes 512 rows (or channel
  IDs, or name entries) at a time, and the JSON feeds one LZFSE stream whose state persists across
  batches and is finalized once. The output equals a one-shot compression of the same JSON, and
  the batch size changes no byte. Key order is not part of the format; sorted keys only keep
  every batch spelled the same way, which keeps the payload small and deterministic. The decoded
  and file size limits are enforced as bytes are produced.
- Verified reads never delete a file they reject. A corrupt, foreign-version or oversized file,
  or one that can't be read for now (for example, while data protection keeps it locked), reads as
  missing and is kept until the legacy cleanup policy below allows its removal or the next
  verified write replaces it.

## Memory

The 64 MiB limit applies to decoded JSON. It does not bound peak process memory. A load also
holds the mapped file, the decoded record, and the index built from it. One host measurement
(arm64 Mac, `/usr/bin/time -l` peak memory footprint, synthetic guides) gave these results:

| Guide | Decoded JSON | Peak footprint |
|---|---|---|
| 123,000 programmes, 500 channels | 25.5 MiB | 151–198 MiB |
| 200,000 programmes, 814 channels | 62.5 MiB | 370 MiB |

The range for the same guide depends on the JSON key order. The Milestone 2A.1 one-shot writer
did not fix key order, and `JSONDecoder`'s peak memory and the compressed size vary with it; the
streamed writer sorts keys, so its output for a given guide is deterministic. The version 2 path itself adds about 2 MiB over
version 1 for the same payload. Device measurements on iPhone and Apple TV are still outstanding.

Known release and performance risks, deliberately not changed in Stage D:

- The process-wide cache transaction lock is held for whole encodes, decodes and promotions,
  which can take seconds for a large guide. A cached read for one provider waits behind another
  provider's write, and each waiting call blocks a Swift concurrency pool thread. The lock does
  not coordinate separate processes, such as two Mac builds sharing one directory.
- Reading persisted state no longer decodes the v2 guide a second time when the cached read
  just validated it: the state read re-checks the file's header and payload digest instead (see
  Stage C storage and state). Without that earlier validation, for example when the file changed
  in between, it still decodes the whole guide.
- Legacy cleanup and migration decode v1 candidates one at a time, but a verified v2 guide stays
  in memory while its v1 counterparts are decoded for deletion.

## Version 1

Version 1 is `KEPG`, the byte `1`, and then the LZFSE payload, with no header. It is read only so
existing caches can migrate. Its decoder uses the same block walk and streaming limit, so it also
rejects bytes after the stream ends. It applies only the structural record checks.

## Stage C storage and state

- iOS and macOS use `Application Support/Silo/LiveTV/Guide`; tvOS uses `Caches/LiveTVGuide`.
  iOS/macOS mark the directory excluded from backup. Guide and state writes retain
  `completeFileProtectionUntilFirstUserAuthentication` and use atomic replacement.
- Stage C used unsuffixed `<uuid>.epgcache` v1 guides. Stage D writes source-bound v2 files as
  `<uuid>.v2.epgcache`, keeps historical v1 files at `<uuid>.epgcache`, and recognizes
  `<uuid>.v1.epgcache` for explicitly renamed legacy v1. Temporary migration files are
  `<uuid>.<nonce-uuid>.stage`, written in the primary directory. iOS/macOS also recognize old v1
  files in `Caches/LiveTVGuide`; tvOS uses the same directory for all versions.
- Each provider may have a bounded (4 KiB maximum) `<uuid>.state` JSON file with schema version,
  provider ID, 32-byte source fingerprint, optional content ID, last successful fetch time,
  failure count, and next retry time. It contains no URLs or HTTP validators. Stage C v1 state has
  no content ID. Its fingerprint and exact last-success timestamp can establish a v1 binding only
  when both match the candidate guide; UUID-only v1 is not source-bound.
- State is accepted only when schema, provider ID, fingerprint, count, and timestamps validate.
  A state with a content ID is accepted only when the fully validated, current-source v2 guide
  carries that exact content ID; missing or unreadable v2 data makes the state unavailable but does
  not delete the state or guide. Successful refresh/restart reads use this same association check.
  When the cached read has already fully validated the v2 guide, the state read reuses that
  result only if the file still has the identical header, including its random content ID and
  payload digest, and its payload still hashes to that digest. That proves it is the same bytes,
  so the guide is not decoded again. Any difference falls back to full validation.
  Missing, malformed, oversized, or temporarily unreadable state is a miss; it does not invalidate
  a guide. Atomic state-write failure leaves the previous state in place. Removal waits for queued
  writes and then deletes state and guides; orphan cleanup is limited to recognized guide/state
  filenames and is a no-op if directory enumeration fails.
- `EPGService` loads a provider's state from disk once per process and source, and concurrent
  refreshes share that load. Disk state never replaces a success or failure the process has
  already recorded, because the in-memory value is newer than any queued write. The state read
  runs on the provider's disk-operation chain, behind every queued write. The store reads the
  file once and deletes it only when that same read was well-formed but invalid, so cleanup can
  never remove a state written after it was judged.
- On iOS/tvOS the Stage B HMAC key currently uses the default Keychain access group, which resolves
  to `com.cubbiestream.kyro.shared`; the Top Shelf and Notification Service entitlements also list
  that group. Neither extension reads the key. Stage C does not change this policy or Mac signing/
  Keychain configuration.
- Before Stage E introduces more source-aware diagnostics, `EPGFeedSource` should implement a
  redacted `CustomStringConvertible`; its Xtream case contains a password and synthesized
  descriptions must not be logged.

## Stage D source and migration behavior (explicitly opt-in)

- `EPGService.index(for:source:)` is the source-aware cached-first entry point. It validates a v2
  HMAC fingerprint against the current source before returning the guide. A v1 guide is returned
  only when persisted state has the matching fingerprint, no content ID, and an exact matching
  success timestamp. Unbound v1 is preserved but not shown or migrated.
- If Keychain access is temporarily unavailable, disk guides are not displayed, deleted, or rebound.
  An already established in-memory guide may remain visible only for the exact source value used to
  fetch or verify it. The source-less cache lookup does not load disk data.
- `EPGService.migrateLegacyCache(providerID:source:)` is the explicit Stage D switch. Startup,
  cached-first restoration, and ordinary refresh do not call it. Integrate only after independent
  review. It serializes with provider disk operations, rechecks source identity and provider
  generation at staging/promotion/deletion boundaries, reopens the stage with the normal v2 reader,
  and deletes v1 only after verified promotion.
- Ordinary successful refreshes write v2 atomically, then write its associated state. If strict v2
  encoding rejects a feed, the prior guide and state remain untouched; the live session may still
  use the newly fetched index, but it will not be cached. Migration preserves v1 in that case.
- Guide and state persistence are **not a transaction**. If guide B is promoted over guide A and
  B's state write fails, B remains the valid guide. A's state bytes may remain, but their content
  ID does not match B and they cannot restore retry metadata for B. A fresh B can still restore
  offline without that state. There is no rollback of B or recovery of A's linked state. Diagnostics
  report the failed operation without claiming that the old guide/state pair survived.
- Promotion has two boundaries: the final generation check admits the verified write; the atomic
  filesystem replacement/move commits it. Invalidation after admission may not prevent that commit.
  Source fingerprints and actor source checks keep the old-source result invisible to the new source.
  Completed provider removal waits for queued persistence (including state writing), then deletes
  its files; an admitted old write cannot resurrect a cache after removal completes.
- Cancellation of a refresh caller withdraws that waiter; if no waiters remain, shared fetch work
  is cancelled before publication. Once a successful result is published, independently queued
  persistence is not owned by the caller. The synchronous store intentionally does not interpret
  Swift task cancellation as an abort: its explicit source-generation gate is checked between
  batches and before promotion admission. It does not interrupt a filesystem replacement already
  admitted. These semantics avoid treating cancellation as corruption; they do not promise rollback.
- V2 write, reopen, promotion, or state-write failures produce a rate-limited diagnostic containing
  only a fixed operation label. It never includes a source, URL, username, password, or arbitrary
  error description.
- Eviction is directory-wide and uses a process-wide cache transaction lock around promotions,
  migration, removal, orphan sweep, and eviction, so one provider cannot evict another provider's
  active stage or promotion. A removed provider UUID is retired for the rest of that EPGService
  lifetime and cannot be revived by delayed work.
- Legacy cleanup policy. A provider's v1 files are deleted in exactly these cases:
  - After a source-bound v2 guide for that provider is verified (cached read), written (refresh) or
    promoted (migration), every v1 file the v1 reader decodes is deleted. The v1 reader applies
    only structural checks, so a readable v1 guide outside current v2 policy is deleted too; the
    verified v2 guide supersedes it. Migration that fails, including on v2 policy, deletes nothing.
  - Budget eviction removes a provider's v2 guide, least recently written first. It then deletes
    that provider's readable v1 files in both directories, so a stale v1 guide cannot resurface.
    Eviction never removes a v1 file on its own, and never removes the guide just written. Legacy
    files in both v1 locations count toward the entry and size limits, each file once even when
    both locations are the same directory. The inventory is re-read after every removal, so
    eviction stops as soon as the cache fits. Eviction deletes only on a complete inventory: if an
    existing directory cannot be listed, or a counted file's size or date cannot be read, it
    removes nothing more. A legacy directory that does not exist counts as empty. When only the
    kept guide and legacy files remain, eviction stops and the cache can stay over its limit until
    one of the cases here or the next verified v2 write removes them.
  - Explicit provider removal, and the orphan sweep for provider IDs no longer configured, delete
    every recognized filename for that provider, whatever its contents.

  Otherwise legacy files are kept, including after cleanup and eviction: v1 files with unknown LZFSE
  framing, files larger than this build's limits, and files unreadable for now. They are never
  displayed unless they later pass verification. Unrecognized filenames are never deleted.
- Short-guide (Xtream) listings are not persisted. Applied without a full guide in memory, they
  form a short-guide-only index: it can be shown, but it never hides the verified cached guide or
  makes a refresh look fresh. When the cached guide loads, the short-guide listings are reapplied on
  top of it; a successful full refresh supersedes them.

## Timestamps

Every guide's `fetchedAt` is canonicalized when its `EPGIndex` is built (`EPGTimestamp`): it is
the `Date` whose 1970-based seconds are exactly the value the header, record and state store.
`Date` itself counts from 2001, and a fractional `Date()` would otherwise lose its lowest bit in
the 1970 conversion about half the time, so a guide read back would not equal the one written.
The mapping is idempotent and moves a time by less than a microsecond, so freshness is unchanged.
Cache verification, state association and v1 binding all compare fetch times by exact equality;
no tolerance is used.

## Stage D migration requirements

These requirements must hold before any version 1 file is converted or deleted.

1. **Both v1 locations.** On iOS and macOS, v1 files can be in the legacy `Caches/LiveTVGuide`
   directory and in the primary directory, where Stage C builds write v1 `.epgcache` files. On
   tvOS both are the same directory. Migration handles every combination, including a provider
   with v1 files in both places, and prefers the newer `fetchedAt`.
2. **Distinct names.** Version 2 files, staging files and v1 files use different, fixed names so
   no reader, sweep or eviction step can mistake one kind for another. Freeze the names before
   writing any code.
3. **Verified v2 wins.** Once a v2 file for a provider has passed full validation, it is the only
   guide used. Delete that provider's v1 files in both directories, and stop the legacy
   fallback read for it, so eviction or corruption can never bring an older v1 guide back.
4. **Stage, reopen, verify, promote, then delete.** Write each candidate to a uniquely named stage
   file in the primary directory. Reopen it through `EPGCacheFormat.decode` and check the provider
   ID, the source fingerprint, every header field and the record. Promote it with an atomic rename
   within that directory. A legacy file in `Caches` is copied into a stage; it is never renamed
   across directories. Only after promotion succeeds may any v1 file be deleted. Any failure
   leaves every existing file untouched.
5. **One serialized chain.** Migration, stage cleanup, invalid-file cleanup, orphan sweeps,
   eviction and provider removal for a provider all run on that provider's disk-operation chain
   in `EPGService`. Removal is always the last operation for its generation, and deletes stage
   files as well as guides and state.
6. **Generation checks.** Recheck the provider's generation immediately before staging, before
   promotion and before each deletion. A stale operation stops without touching disk.
7. **Stage files in sweep and eviction.** Orphan sweeps and eviction recognise stage files. They
   never count or delete a stage that is still being written. Both remove only recognized stages
   older than 24 hours, conservatively allowing a delayed/retrying writer or another process
   sharing the container to finish. Stages never count toward the eviction budget.
8. **Identity first.** Migrate only when the source fingerprint is available. If the Keychain key
   is unavailable, preserve v1 and retry later, but don't display an unverified disk v1 guide. An
   already verified in-memory guide may remain visible only for the exact source value that was
   verified. If a state file's fingerprint differs from the current source, don't bind that v1
   guide to the current source. Binding v1 to the current fingerprint is safe only while provider
   sources can't be edited; this assumption must be restated wherever migration binds identity.
9. **Never delete what migration couldn't read.** A v1 file that the block walker or decoder
   rejects during migration stays in place and is reported. It is deleted only once a verified
   replacement has been promoted, or by the normal v1 corrupt-file path, which is unchanged.
10. **Verify the encoder too.** The reopen check in step 4 also guards against a mismatch between
    Apple's encoder and the block walker, so an unreadable v2 file is never promoted.

## Stage E integration (migration still disabled)

Normal app startup, cached restore, and refresh use the source-bound v2 guide only. They do not
call `EPGService.migrateLegacyCache(providerID:source:)`. That method is the only switch that
converts or deletes a legacy v1 guide; leave it unwired until an independent review enables it.

- A verified v2 guide is shown before any network refresh, including when the refresh then fails.
- A new `EPGService` / `LiveTVService` reads that same v2 file and its linked retry state.
- Provider removal deletes the v2 guide, state, and stage files, and a later launch does not
  recreate them.
- A changed source fingerprint does not display the previous source's v2 guide.
- A readable v1 guide may still be shown when Stage C state binds it, but startup does not write
  a v2 file or delete that v1 file.
- Xtream short-guide listings can update one channel of a full guide. They cannot replace that
  guide with a short-guide-only index, mark the full guide fresh, or send `If-None-Match` /
  `If-Modified-Since`. Conditional requests remain M2B.
- A short-guide response is applied only with the ticket issued before its request was sent
  (`EPGService.beginShortRequest` / `applyShortPrograms`). It is dropped when a full guide was
  published after the request began, when the provider was removed or its source changed, or when
  a newer request for the same channel has already applied. Otherwise it applies as before. Tickets
  are per channel and need no global lock.
- `EPGFeedSource` descriptions and reflection expose only `EPGFeedSource.xmltv(redacted)` or
  `EPGFeedSource.xtream(redacted)`.
