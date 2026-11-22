# Argon2 reference dependency

Unmodified portable C implementation from https://github.com/P-H-C/phc-winner-argon2
release 20190702, commit 62358ba2123abd17fccf2a108a301d4b52c01a7c.
The selected files implement the reference algorithm (not SIMD). The upstream
LICENSE is retained. SwiftPM builds with ARGON2_NO_THREADS; Kyro uses one lane.
No platform crypto or custom derivation algorithm is substituted.

Kyro uses Argon2id v19, 19 MiB, two passes, one lane, a 128-bit random salt and
256-bit output. Cost parameters are persisted and validated before allocation.
Verification uses upstream argon2id_verify, including its constant-time compare.
Low entropy PINs still require attempt limits and cannot protect an unencrypted
database against a determined offline attacker. This is a profile access gate,
not database encryption or a replacement for device security.
