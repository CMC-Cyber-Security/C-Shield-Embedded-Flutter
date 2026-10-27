import 'dart:typed_data';

import 'package:c_shield_embedded/src/api/attest/c_shield_state.dart';
import 'package:c_shield_embedded/src/api/attest/ensure_trust_result.dart';
import 'package:c_shield_embedded/src/api/attest/trust_level.dart';
import 'package:c_shield_embedded/src/api/event/c_shield_event.dart';
import 'package:c_shield_embedded/src/api/malware/models.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'c_shield_embedded_method_channel.dart';

abstract class CShieldEmbeddedPlatform extends PlatformInterface {
  /// Constructs a CShieldEmbeddedPlatform.
  CShieldEmbeddedPlatform() : super(token: _token);

  static final Object _token = Object();

  static CShieldEmbeddedPlatform _instance = MethodChannelCShieldEmbedded();

  /// The default instance of [CShieldEmbeddedPlatform] to use.
  ///
  /// Defaults to [MethodChannelCShieldEmbedded].
  static CShieldEmbeddedPlatform get instance => _instance;

  /// Platform-specific implementations should set this with their own
  /// platform-specific class that extends [CShieldEmbeddedPlatform] when
  /// they register themselves.
  static set instance(CShieldEmbeddedPlatform instance) {
    PlatformInterface.verifyToken(instance, _token);
    _instance = instance;
  }

  // ── SDK ──────────────────────────────────────────────────────────────────
  Future<void> initialize({required String license}) => throw UnimplementedError();

  /// Stream of native license lifecycle events (renewed / revoked).
  Stream<CShieldEvent> get events => throw UnimplementedError();

  // ── SSL ──────────────────────────────────────────────────────────────────
  // R5 — multi-host. H-3 — allowRuntimeUpdates=false (mặc định) ⇒ native auto-seal.
  Future<void> sslConfigure({required Map<String, List<String>> pinsByHost, bool allowRuntimeUpdates = false}) => throw UnimplementedError();

  Future<void> sslUpdatePins({required List<String> pins, required String hostname}) => throw UnimplementedError();

  Future<bool> sslIsConfigured() => throw UnimplementedError();

  Future<bool> sslCheckServerTrusted({required String certDerBase64, required String host}) =>
      throw UnimplementedError();

  /// Executes an HTTPS request on the native side (OkHttp / URLSession) with
  /// certificate pinning enforced over the full chain.
  ///
  /// Returns a map: `{ 'statusCode': int, 'headers': Map<String, List<String>>, 'body': Uint8List, 'reasonPhrase': String? }`.
  Future<Map<Object?, Object?>> sslHttpRequest({
    required String method,
    required String url,
    required Map<String, String> headers,
    Uint8List? body,
    int? connectTimeoutMs,
    int? receiveTimeoutMs,
    bool followRedirects = true,
  }) =>
      throw UnimplementedError();

  // ── AIP ──────────────────────────────────────────────────────────────────
  // Only the cryptographic sign/verify cross to native (they need the device
  // key and proxy-CA check). Body normalization, payload construction, hashing
  // and the timestamp-window check all happen in Dart (see AIPNormalizer /
  // CShieldAIP) — no fabricated request URL required.
  Future<void> aipVerify({required String payload, required String signature}) => throw UnimplementedError();

  Future<Map<Object?, Object?>> aipSignRequest({
    required String method,
    required String path,
    required String canonicalQuery,
    required int timestampSec,
    required String bodyHashHex,
  }) =>
      throw UnimplementedError();

  /// Force refresh token khi server 401 invalid-token. Trả `true` nếu sau đó đã sẵn sàng.
  Future<bool> aipForceRefresh({int timeoutMs = 5000}) => throw UnimplementedError();

  // ── Attestation v2 ────────────────────────────────────────────────────────
  // Readiness + trust level. Nền tảng chưa hỗ trợ (iOS) → implementation trả giá trị "không khả
  // dụng" thay vì ném, để app dùng chung một luồng (xem CShieldAttest).

  Future<CShieldState> attestState() => throw UnimplementedError();

  Future<String?> attestLastError() => throw UnimplementedError();

  Future<CShieldState> attestAwaitReady({int timeoutMs = 8000}) => throw UnimplementedError();

  Future<TrustLevel> attestCurrentTrustLevel() => throw UnimplementedError();

  Future<EnsureTrustResult> attestEnsureTrust({
    required TrustLevel minLevel,
    bool requireFresh = false,
    int timeoutMs = 15000,
  }) =>
      throw UnimplementedError();

  // ── Anti Malware ──────────────────────────────────────────────────────────────────
  Future<DeviceScanResult> scanDevice() => throw UnimplementedError();

  Future<ScannedPackage> analyzeApkFile(String filePath) => throw UnimplementedError();

  Future<ScannedPackage> analyzeInstalledApp(String packageName) => throw UnimplementedError();

  Future<void> stopScan() => throw UnimplementedError();
}
