/// Result of `CShieldAttest.ensureTrust` (mirrors the native
/// `EnsureTrustResult`). The app reads it to decide whether to let a sensitive
/// flow continue, block it, or offer a reduced feature.
///
///  - [satisfied]: the requested trust level is reached, and is fresh if
///    `requireFresh` was set. Continue.
///  - [insufficient]: the SDK tried to raise trust but the device cannot reach
///    the level (for example a software-only device, or one without Google
///    Play services, cannot reach L4). The app decides whether to block or
///    degrade.
///  - [rateLimited]: Play Integrity hit a rate limit or quota. Transient: retry
///    later. The current trust level is **not** lowered.
///  - [timeout]: `timeoutMs` elapsed, or a transient server error (5xx,
///    timeout) happened before trust was raised. Transient: retry later.
///  - [offline]: no internet connection when the attestation server had to be
///    reached. Unlike [insufficient], this says nothing about the device's
///    security: ask the user to check the connection and retry instead of
///    blocking the device.
///  - [unavailable]: attestation is permanently unavailable (not initialized,
///    missing license, or an unsupported device or platform). Do not retry.
enum EnsureTrustResult {
  satisfied('SATISFIED'),
  insufficient('INSUFFICIENT'),
  rateLimited('RATE_LIMITED'),
  timeout('TIMEOUT'),
  offline('OFFLINE'),
  unavailable('UNAVAILABLE');

  const EnsureTrustResult(this.id);

  /// The name used across the method channel (matches the native enum name).
  final String id;

  /// Maps a native name to an [EnsureTrustResult]. Anything unrecognized maps
  /// to [unavailable] (fail-closed).
  static EnsureTrustResult fromId(String? value) {
    final v = (value ?? '').trim().toUpperCase();
    return values.firstWhere((e) => e.id == v, orElse: () => unavailable);
  }
}
