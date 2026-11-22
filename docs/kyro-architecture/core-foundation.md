# KyroMediaCore foundation

KyroMediaCore is an independent Swift package. It defines stable identities, profile-scoped operations, canonical media records, source parsing, playback contracts, and capability declarations without importing application modules.

The package uses SQLite for durable state and Swift Crypto for cryptographic primitives. Credential material is represented by a store protocol; no PIN derivation is implemented until a vetted cross-platform password KDF has been selected and reviewed. Current catalog matching is intentionally conservative groundwork and is not yet acceptance-complete.
