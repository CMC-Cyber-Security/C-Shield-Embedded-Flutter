enum CShieldErrorCode {
  aipMissingHeader('aip_missing_header'),
  aipTimestampExpired('aip_timestamp_expired'),
  aipInvalidSignature('aip_invalid_signature'),
  aipSigningFailed('aip_signing_failed'),
  aipDetectProxyCA('aip_proxy_ca'),
  sslNotConfigured('ssl_not_configured'),
  sslPinMismatch('ssl_pin_mismatch'),
  notInitialized('not_initialized'),

  /// Attestation chưa sẵn sàng khi ký request (hardware key/token chưa có). Native gửi kèm
  /// [CShieldException.retryable] + [CShieldException.state] để phân luồng xử lý:
  ///  - `retryable == true` (INITIALIZING / lỗi tạm thời) → chờ sẵn sàng rồi thử lại.
  ///  - `retryable == false` (state `UNAVAILABLE`) → lỗi vĩnh viễn, ĐỪNG retry; đọc [CShieldException.message]
  ///    (mã lỗi ổn định: `device_blocked` / `attestation_not_enabled` / `device_unsupported` / … ) để xử lý.
  notReady('not_ready'),

  /// `ensureTrust` được gọi nhưng Play Integrity CHƯA cấu hình — `initialize` không truyền
  /// `cloudProjectNumber` (chủ động chọn KHÔNG dùng PI). Không có PI thì không elevate trust được.
  /// Cách xử lý: hoặc truyền `cloudProjectNumber` để bật PI, hoặc đừng gọi `ensureTrust`/đặt
  /// `requiredLevel` ở interceptor (thiết bị vẫn KA-only + ký request bình thường). **Chỉ Android.**
  playIntegrityNotConfigured('play_integrity_not_configured'),

  invalidArgument('invalid_argument'),
  nativeError('native_error');

  const CShieldErrorCode(this.platformCode);

  /// The string code used on the native platform (Android/iOS) side.
  final String platformCode;

  static CShieldErrorCode fromPlatformCode(String code) => values.firstWhere((e) => e.platformCode == code, orElse: () => nativeError);
}

class CShieldException implements Exception {
  final CShieldErrorCode code;
  final String message;
  final Object? nativeCause;

  /// Chỉ có nghĩa với [CShieldErrorCode.notReady]: `true` nếu nên chờ/thử lại (tạm thời),
  /// `false` nếu vĩnh viễn (ĐỪNG retry). `null` với các lỗi khác.
  final bool? retryable;

  /// Tên trạng thái attestation native khi biết được: `INITIALIZING` / `READY` / `DEGRADED` /
  /// `UNAVAILABLE`. `null` với các lỗi không mang trạng thái.
  final String? state;

  const CShieldException(this.code, this.message, [this.nativeCause, this.retryable, this.state]);

  @override
  String toString() {
    final extra = code == CShieldErrorCode.notReady ? ' [retryable=$retryable, state=$state]' : '';
    return 'CShieldException(${code.name}): $message$extra';
  }
}
