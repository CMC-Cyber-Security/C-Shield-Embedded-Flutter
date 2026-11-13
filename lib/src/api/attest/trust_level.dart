/// Device trust level on the L0–L5 scale (mirrors the native and backend
/// `TrustLevel`), used with `CShieldAttest.ensureTrust` and
/// `CShieldAttest.currentTrustLevel`.
///
///  - [l0] UNTRUSTED
///  - [l1] WEAK
///  - [l2] BASIC
///  - [l3] PARTIAL: one strong pillar, the other unknown (for example a TEE
///    key with Play Integrity not run yet)
///  - [l4] HARDWARE: TEE plus a passing Play Integrity verdict
///  - [l5] STRONG: StrongBox plus a strong Play Integrity verdict
///  - [unknown]: no token yet, or not registered. Ranks lowest in [atLeast].
///
/// The value is read from the access token the device holds and is meant for
/// **client-side routing only** (deciding whether to raise trust before a
/// sensitive call). The **server** enforces security, by verifying the token
/// and applying a minimum trust level per route. A client cannot forge a
/// higher level, because the token is signed by the backend.
///
/// iOS reaches **L4** at most: the Secure Enclave maps to the "TEE" row and
/// there is no StrongBox. A minimum of [l5] therefore blocks every iOS device.
enum TrustLevel {
  unknown(-1, 'UNKNOWN'),
  l0(0, 'L0'),
  l1(1, 'L1'),
  l2(2, 'L2'),
  l3(3, 'L3'),
  l4(4, 'L4'),
  l5(5, 'L5');

  const TrustLevel(this.rank, this.id);

  /// Rank used to compare levels ([unknown] is -1, below every real level).
  final int rank;

  /// The name used across the method channel (matches the native enum name).
  final String id;

  /// `true` if this level is at or above [other] on the L0–L5 scale.
  bool atLeast(TrustLevel other) => rank >= other.rank;

  /// Maps a native name (`"L0"`..`"L5"` or `"UNKNOWN"`, case-insensitive) to a
  /// [TrustLevel]. Empty or unrecognized input maps to [unknown].
  static TrustLevel fromId(String? value) {
    final v = (value ?? '').trim().toUpperCase();
    return values.firstWhere((e) => e.id == v, orElse: () => unknown);
  }
}
