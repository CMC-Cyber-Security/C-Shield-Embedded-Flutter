import 'dart:typed_data';

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
  Future<void> initialize() => throw UnimplementedError();

  // ── SSL ──────────────────────────────────────────────────────────────────
  Future<void> sslConfigure({required List<String> pins, required String hostname}) => throw UnimplementedError();

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
  Future<String> aipSign({required String payload}) => throw UnimplementedError();

  Future<void> aipVerify({required String payload, required String signature}) => throw UnimplementedError();

  Future<Map<Object?, Object?>> aipSignRequest({
    required String method,
    required String path,
    required String canonicalQuery,
    required int timestampSec,
    required String bodyHashHex,
  }) =>
      throw UnimplementedError();
}
