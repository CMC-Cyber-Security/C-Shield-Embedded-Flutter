import 'package:c_shield_embedded/src/api/aip/c_shield_aip.dart';
import 'package:c_shield_embedded/src/api/attest/c_shield_state.dart';
import 'package:c_shield_embedded/src/api/attest/ensure_trust_result.dart';
import 'package:c_shield_embedded/src/api/attest/trust_level.dart';
import 'package:c_shield_embedded/src/api/event/c_shield_event.dart';
import 'package:c_shield_embedded/src/internal/platform/c_shield_embedded_platform_interface.dart';

/// Device attestation: the device proves its identity and integrity with its
/// secure hardware and receives an access token that carries a **trust level**
/// signed by the backend. The server verifies the token offline (JWKS) and
/// enforces a minimum trust level per route.
///
/// Supported on **Android** (Key Attestation over TEE/StrongBox, plus Play
/// Integrity; up to L5) and **iOS** (Apple App Attest on the Secure Enclave;
/// up to **L4**, since there is no StrongBox).
///
/// Enrollment starts in the background from `CShieldEmbedded.initialize`.
///
/// ## Cheap by default, expensive on demand
/// On Android, enrollment and ordinary refresh run Key Attestation only, which
/// costs no Play Integrity quota, so most real (TEE) devices settle at **L3**.
/// To reach **L4+** for a sensitive flow, the app calls [ensureTrust] first;
/// only then does the SDK run Play Integrity (one quota unit).
///
/// ## Usage
/// ```dart
/// // 1) Entering a sensitive screen (payment): call BEFORE the API request.
/// final r = await CShieldAttest.ensureTrust(TrustLevel.l4);
/// switch (r) {
///   case EnsureTrustResult.satisfied:    await goPayment();
///   case EnsureTrustResult.insufficient: block('Device does not meet the required security level');
///   case EnsureTrustResult.offline:      showError('No internet connection');
///   case EnsureTrustResult.rateLimited:
///   case EnsureTrustResult.timeout:      retryLater();
///   case EnsureTrustResult.unavailable:  notSupported();
/// }
///
/// // 2) A highly sensitive action (the route sets maxTrustAgeSeconds): ask for
/// //    FRESH proof.
/// await CShieldAttest.ensureTrust(TrustLevel.l4, requireFresh: true);
/// ```
///
/// When the server answers `403 CSHIELD_DEVICE_NOT_ALLOWED`, trust is too low:
/// call `ensureTrust(level)`. When it answers `403 CSHIELD_TRUST_NOT_FRESH`,
/// trust is high enough but too old: call
/// `ensureTrust(level, requireFresh: true)`.
///
/// If a platform build does not implement an attestation method (for example
/// an older native SDK), the calls return the "not available" value
/// ([CShieldState.unavailable], [TrustLevel.unknown],
/// [EnsureTrustResult.unavailable]) instead of throwing, so the app can use
/// one code path on every platform.
class CShieldAttest {
  CShieldAttest._();

  /// The current attestation state. Returns [CShieldState.unavailable] when the
  /// SDK is not initialized or the license is missing.
  static Future<CShieldState> state() => CShieldEmbeddedPlatform.instance.attestState();

  /// The latest **stable** error code of the registration/refresh flow
  /// (`device_blocked`, `challenge_rejected`, `attestation_not_enabled`,
  /// `device_unsupported`, `attestation_rejected`, `key_already_bound`,
  /// `transport_auth`, `network`, `rate_limited`, …), or `null` if there has
  /// been no error.
  ///
  /// When [state] is [CShieldState.unavailable], this is the permanent reason
  /// (show or report it as appropriate). When it is
  /// [CShieldState.initializing], this is the transient problem currently
  /// being retried in the background.
  static Future<String?> lastError() => CShieldEmbeddedPlatform.instance.attestLastError();

  /// Waits until attestation is ready, or [timeoutMs] elapses, and returns the
  /// final [CShieldState]. Use it when the app prefers to hold a splash screen
  /// until attestation finishes rather than let the first request fail.
  ///
  /// It waits for the attestation run that `initialize` already started; it
  /// does not start a second one.
  static Future<CShieldState> awaitReady({int timeoutMs = 8000}) =>
      CShieldEmbeddedPlatform.instance.attestAwaitReady(timeoutMs: timeoutMs);

  /// The current trust level, read from the access token the device holds.
  /// Returns [TrustLevel.unknown] when the SDK is not initialized or the device
  /// is not registered. For client-side routing only; the server is what
  /// enforces trust.
  static Future<TrustLevel> currentTrustLevel() => CShieldEmbeddedPlatform.instance.attestCurrentTrustLevel();

  /// Makes sure the device reaches a trust level of at least [minLevel]
  /// **before** a sensitive flow (an API that needs L4+).
  ///
  ///  - Trust is already sufficient and [requireFresh] is `false`: returns
  ///    [EnsureTrustResult.satisfied] immediately, at no Play Integrity cost.
  ///  - Trust is too low, or [requireFresh] is `true` (a highly sensitive API
  ///    that needs proof taken at the time of the action): raises trust with a
  ///    refresh that includes the stronger check. On Android that is Play
  ///    Integrity and spends quota.
  ///
  /// [timeoutMs] should be generous (15 seconds by default) because Play
  /// Integrity may have to run (prepare and request). The final decision to
  /// block or allow remains with the server and the app.
  ///
  /// On Android, throws a `CShieldException` with code
  /// `CShieldErrorCode.playIntegrityNotConfigured` if `initialize` was called
  /// without `cloudProjectNumber`.
  static Future<EnsureTrustResult> ensureTrust(
    TrustLevel minLevel, {
    bool requireFresh = false,
    int timeoutMs = 15000,
  }) {
    assert(minLevel != TrustLevel.unknown, 'ensureTrust needs a level from L0 to L5, not TrustLevel.unknown');
    return CShieldEmbeddedPlatform.instance
        .attestEnsureTrust(minLevel: minLevel, requireFresh: requireFresh, timeoutMs: timeoutMs);
  }

  /// Refreshes the access token right away, for when the server rejects the
  /// current one (`401 CSHIELD_INVALID_ACCESS_TOKEN`). Returns `true` if a new
  /// token is ready afterwards.
  ///
  /// The SDK's interceptors already do this once per request. Call it yourself
  /// only when you build your own HTTP client.
  static Future<bool> forceRefresh({int timeoutMs = 5000}) => CShieldAIP.forceRefresh(timeoutMs: timeoutMs);

  /// Stream of attestation state changes, pushed by the native side over the
  /// event channel. It emits the current state as soon as you subscribe, so
  /// there is no need to poll [state].
  ///
  /// ```dart
  /// CShieldAttest.stateChanges.listen((e) => setState(() => _state = e.state));
  /// ```
  static Stream<AttestStateChanged> get stateChanges =>
      CShieldEmbeddedPlatform.instance.events.where((e) => e is AttestStateChanged).cast<AttestStateChanged>();
}
