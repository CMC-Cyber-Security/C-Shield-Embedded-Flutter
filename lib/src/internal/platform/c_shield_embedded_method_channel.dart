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

  @override
  Future<bool> aipForceRefresh({int timeoutMs = 5000}) =>
      _invoke<bool>(CShieldChannels.aipForceRefresh, {'timeoutMs': timeoutMs});

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
