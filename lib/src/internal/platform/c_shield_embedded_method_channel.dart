import 'package:c_shield_embedded/src/api/attest/c_shield_state.dart';
import 'package:c_shield_embedded/src/api/attest/ensure_trust_result.dart';
import 'package:c_shield_embedded/src/api/attest/trust_level.dart';
import 'package:c_shield_embedded/src/api/exceptions/c_shield_exception.dart';
import 'package:c_shield_embedded/src/api/event/c_shield_event.dart';
import 'package:c_shield_embedded/src/api/malware/models.dart';
import 'package:c_shield_embedded/src/internal/channels.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'c_shield_embedded_platform_interface.dart';

/// An implementation of [CShieldEmbeddedPlatform] that uses method channels.
class MethodChannelCShieldEmbedded extends CShieldEmbeddedPlatform {
  /// The method channel used to interact with the native platform.
  @visibleForTesting
  final methodChannel = const MethodChannel('c_shield_embedded');

  /// The event channel that streams native license lifecycle callbacks.
  @visibleForTesting
  final eventChannel = const EventChannel(CShieldChannels.eventChannel);

  Stream<CShieldEvent>? _events;

  // Native call
  Future<T> _invoke<T>(String method, [dynamic args]) async {
    try {
      return await methodChannel.invokeMethod<T>(method, args) as T;
    } on PlatformException catch (e) {
      // Giữ phân loại retryable/state mà native gửi kèm (vd not_ready) — trước đây `details` bị bỏ
      // và "not_ready" rơi về nativeError, mất sạch thông tin để app xử lý (chờ/retry vs block).
      bool? retryable;
      String? state;
      final details = e.details;
      if (details is Map) {
        final r = details['retryable'];
        if (r is bool) retryable = r;
        final s = details['state'];
        if (s is String) state = s;
      }
      throw CShieldException(CShieldErrorCode.fromPlatformCode(e.code), e.message ?? e.code, e, retryable, state);
    }
  }

  /// Như [_invoke] nhưng nuốt [MissingPluginException] → `null`: nền tảng chưa cài đặt method đó
  /// (iOS chưa có attest v2) thì coi là "không khả dụng" thay vì nổ lên app. Lỗi native THẬT
  /// (PlatformException) vẫn ném như thường.
  Future<T?> _invokeOptional<T>(String method, [dynamic args]) async {
    try {
      return await _invoke<T?>(method, args);
    } on MissingPluginException {
      return null;
    }
  }

  // ── Initialization ──────────────────────────────────────────────────────────────────

  @override
  Future<void> initialize({required String license}) => _invoke(CShieldChannels.sdkInitialize, {'license': license});

  @override
  Stream<CShieldEvent> get events => _events ??= eventChannel
      .receiveBroadcastStream()
      .map((event) => CShieldEvent.fromMap((event as Map).cast<Object?, Object?>()));

  // ── SSL ──────────────────────────────────────────────────────────────────

  @override
  Future<void> sslConfigure({required Map<String, List<String>> pinsByHost, bool allowRuntimeUpdates = false}) =>
      _invoke(CShieldChannels.sslConfigure, {'pinsByHost': pinsByHost, 'allowRuntimeUpdates': allowRuntimeUpdates});

  @override
  Future<void> sslUpdatePins({required List<String> pins, required String hostname}) =>
      _invoke(CShieldChannels.sslUpdatePins, {'pins': pins, 'hostname': hostname});

  @override
  Future<bool> sslIsConfigured() => _invoke<bool>(CShieldChannels.sslIsConfigured);

  @override
  Future<bool> sslCheckServerTrusted({required String certDerBase64, required String host}) =>
      _invoke<bool>(CShieldChannels.sslCheckServerTrusted, {'certDer': certDerBase64, 'host': host});

  @override
  Future<Map<Object?, Object?>> sslHttpRequest({
    required String method,
    required String url,
    required Map<String, String> headers,
    Uint8List? body,
    int? connectTimeoutMs,
    int? receiveTimeoutMs,
    bool followRedirects = true,
  }) =>
      _invoke<Map<Object?, Object?>>(CShieldChannels.sslHttpRequest, {
        'method': method,
        'url': url,
        'headers': headers,
        'body': body,
        'connectTimeoutMs': connectTimeoutMs,
        'receiveTimeoutMs': receiveTimeoutMs,
        'followRedirects': followRedirects,
      });

  // ── AIP ──────────────────────────────────────────────────────────────────
  // Only sign/verify cross to native; normalization and payload construction
  // are done in Dart (see CShieldAIP / AIPNormalizer).

  @override
  Future<void> aipVerify({required String payload, required String signature}) =>
      _invoke(CShieldChannels.aipVerify, {'payload': payload, 'signature': signature});

  @override
  Future<Map<Object?, Object?>> aipSignRequest({
    required String method,
    required String path,
    required String canonicalQuery,
    required int timestampSec,
    required String bodyHashHex,
  }) =>
      _invoke<Map<Object?, Object?>>(CShieldChannels.aipSignRequest, {
        'method': method,
        'path': path,
        'canonicalQuery': canonicalQuery,
        'timestampSec': timestampSec,
        'bodyHashHex': bodyHashHex,
      });

  // Nền tảng chưa có attest v2 (iOS) → không có method này: coi như "không refresh được" (false)
  // thay vì để MissingPluginException nổ ra khỏi interceptor giữa luồng retry 401.
  @override
  Future<bool> aipForceRefresh({int timeoutMs = 5000}) async =>
      await _invokeOptional<bool>(CShieldChannels.aipForceRefresh, {'timeoutMs': timeoutMs}) ?? false;

  // ── Attestation v2 ────────────────────────────────────────────────────────
  // Native trả TÊN enum (String); map về enum Dart ở đây — một chỗ duy nhất. Thiếu method (nền
  // tảng chưa hỗ trợ) → null → fromId trả mức "không khả dụng" (fail-closed).

  @override
  Future<CShieldState> attestState() async =>
      CShieldState.fromId(await _invokeOptional<String>(CShieldChannels.attestState));

  @override
  Future<String?> attestLastError() => _invokeOptional<String>(CShieldChannels.attestLastError);

  @override
  Future<CShieldState> attestAwaitReady({int timeoutMs = 8000}) async => CShieldState.fromId(
      await _invokeOptional<String>(CShieldChannels.attestAwaitReady, {'timeoutMs': timeoutMs}));

  @override
  Future<TrustLevel> attestCurrentTrustLevel() async =>
      TrustLevel.fromId(await _invokeOptional<String>(CShieldChannels.attestCurrentTrustLevel));

  @override
  Future<EnsureTrustResult> attestEnsureTrust({
    required TrustLevel minLevel,
    bool requireFresh = false,
    int timeoutMs = 15000,
  }) async =>
      EnsureTrustResult.fromId(await _invokeOptional<String>(CShieldChannels.attestEnsureTrust, {
        'minLevel': minLevel.id,
        'requireFresh': requireFresh,
        'timeoutMs': timeoutMs,
      }));

  @override
  Future<DeviceScanResult> scanDevice() async {
    final result = await _invoke<Map>(CShieldChannels.malwareScanDevice);
    return DeviceScanResult.fromMap(result);
  }

  @override
  Future<ScannedPackage> analyzeApkFile(String filePath) async {
    final result = await _invoke<Map<Object?, Object?>>(CShieldChannels.malwareAnalyzeApkFile, {'filePath': filePath});
    return ScannedPackage.fromMap(result);
  }

  @override
  Future<ScannedPackage> analyzeInstalledApp(String packageName) async {
    final result =
        await _invoke<Map<Object?, Object?>>(CShieldChannels.malwareAnalyzeInstalledApp, {'packageName': packageName});
    return ScannedPackage.fromMap(result);
  }

  @override
  Future<void> stopScan() => _invoke<void>(CShieldChannels.malwareStopScan);
}
