enum CShieldErrorCode {
  aipMissingHeader('aip_missing_header'),
  aipTimestampExpired('aip_timestamp_expired'),
  aipInvalidSignature('aip_invalid_signature'),
  aipSigningFailed('aip_signing_failed'),
  aipDetectProxyCA('aip_proxy_ca'),
  sslNotConfigured('ssl_not_configured'),
  sslPinMismatch('ssl_pin_mismatch'),
  notInitialized('not_initialized'),

  /// Attestation was not ready when a request had to be signed (no hardware
  /// key or access token yet). The native side also sends
  /// [CShieldException.retryable] and [CShieldException.state], which tell the
  /// caller what to do:
  ///  - `retryable == true` (still initializing, or a transient error): wait
  ///    until attestation is ready, then retry.
  ///  - `retryable == false` (state `UNAVAILABLE`): permanent, do **not**
  ///    retry. [CShieldException.message] carries the stable reason code
  ///    (`device_blocked`, `attestation_not_enabled`, `device_unsupported`, …).
  notReady('not_ready'),

  /// `ensureTrust` was called but Play Integrity is not configured:
  /// `initialize` was given no `cloudProjectNumber`, which deliberately turns
  /// Play Integrity off. Without it, trust cannot be raised.
  ///
  /// Either pass `cloudProjectNumber` to enable Play Integrity, or do not call
  /// `ensureTrust` and do not set `requiredLevel` on the interceptors. The
  /// device still signs requests normally using Key Attestation only.
  /// **Android only.**
  playIntegrityNotConfigured('play_integrity_not_configured'),

  /// The feature does not exist on the current platform, by the nature of the
  /// platform. For example, anti-malware on iOS: the sandbox does not let an
  /// app scan other apps. Check `CShieldMalware.isSupported` first.
  unsupportedPlatform('unsupported_platform'),

  invalidArgument('invalid_argument'),
  nativeError('native_error');

  const CShieldErrorCode(this.platformCode);

  /// The string code used on the native platform (Android/iOS) side.
  final String platformCode;

  /// Maps a native code to a [CShieldErrorCode]. Unknown codes map to
  /// [nativeError].
  static CShieldErrorCode fromPlatformCode(String code) => values.firstWhere((e) => e.platformCode == code, orElse: () => nativeError);
}

/// The single exception type thrown by the SDK.
class CShieldException implements Exception {
  /// What went wrong.
  final CShieldErrorCode code;

  /// Human-readable description. For [CShieldErrorCode.notReady] with
  /// `retryable == false`, this is the stable reason code.
  final String message;

  /// The underlying native error, if any.
  final Object? nativeCause;

  /// Only meaningful for [CShieldErrorCode.notReady]: `true` if the caller
  /// should wait and retry (transient), `false` if the failure is permanent
  /// (do not retry). `null` for every other code.
  final bool? retryable;

  /// The native attestation state when known: `INITIALIZING`, `READY`,
  /// `DEGRADED` or `UNAVAILABLE`. `null` for errors that carry no state.
  final String? state;

  const CShieldException(this.code, this.message, [this.nativeCause, this.retryable, this.state]);

  @override
  String toString() {
    final extra = code == CShieldErrorCode.notReady ? ' [retryable=$retryable, state=$state]' : '';
    return 'CShieldException(${code.name}): $message$extra';
  }
}
