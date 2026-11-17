/// Readiness of device attestation (mirrors the native `CShieldState`). The
/// app reads it to react deterministically while attestation has not finished,
/// instead of failing closed without knowing why.
///
///  - [initializing]: registration or refresh is running in the background and
///    there is no usable token yet. Transient: wait or retry.
///  - [ready]: a valid access token and hardware key are present. Requests can
///    be signed.
///  - [degraded]: ready, but trust is low (L0/L1). The server may reject some
///    endpoints.
///  - [unavailable]: the device does not support attestation, registration was
///    rejected permanently, or the SDK is not initialized. Do **not** retry.
enum CShieldState {
  initializing('INITIALIZING'),
  ready('READY'),
  degraded('DEGRADED'),
  unavailable('UNAVAILABLE');

  const CShieldState(this.id);

  /// The name used across the method channel (matches the native enum name).
  final String id;

  /// Maps a native name to a [CShieldState]. Anything unrecognized maps to
  /// [unavailable] (fail-closed).
  static CShieldState fromId(String? value) {
    final v = (value ?? '').trim().toUpperCase();
    return values.firstWhere((e) => e.id == v, orElse: () => unavailable);
  }
}
