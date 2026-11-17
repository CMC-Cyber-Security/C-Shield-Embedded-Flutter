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

  /// The event channel that streams native SDK events (license lifecycle,
  /// attestation state, overlay / touch-guard / keylogger detections).
  @visibleForTesting
  final eventChannel = const EventChannel(CShieldChannels.eventChannel);

  Stream<CShieldEvent>? _events;

  /// Invokes a native method and converts a [PlatformException] into a
  /// [CShieldException].
  Future<T> _invoke<T>(String method, [dynamic args]) async {
    try {
      return await methodChannel.invokeMethod<T>(method, args) as T;
    } on PlatformException catch (e) {
      // Keep the retryable/state classification the native side attaches in `details` (for
      // example with not_ready), so the app can tell "wait and retry" from "blocked".
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

  /// Like [_invoke], but turns a [MissingPluginException] into `null`: when a platform build
  /// does not implement the method (for example an older native SDK), the feature is treated as
  /// "not available" instead of crashing the app. REAL native errors (PlatformException) are
  /// still thrown as usual.
  Future<T?> _invokeOptional<T>(String method, [dynamic args]) async {
    try {
      return await _invoke<T?>(method, args);
    } on MissingPluginException {
      return null;
    }
  }

  // ── Initialization ──────────────────────────────────────────────────────────────────

  @override
  Future<void> initialize({required String license, String? cloudProjectNumber}) =>
      _invoke(CShieldChannels.sdkInitialize, {
        'license': license,
        // null ⇒ the key is not sent → the native side treats Play Integrity as disabled
        // (Key Attestation only).
        if (cloudProjectNumber != null) 'cloudProjectNumber': cloudProjectNumber,
      });

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

  // A platform build without this method counts as "could not refresh" (false), instead of
  // letting a MissingPluginException escape from an interceptor in the middle of a 401 retry.
  @override
  Future<bool> aipForceRefresh({int timeoutMs = 5000}) async =>
      await _invokeOptional<bool>(CShieldChannels.aipForceRefresh, {'timeoutMs': timeoutMs}) ?? false;

  // ── Attestation ───────────────────────────────────────────────────────────
  // The native side returns enum NAMES (strings); they are mapped to Dart enums here, in one
  // place. A missing method (unsupported platform build) → null → fromId returns the
  // "not available" value (fail-closed).

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

  // ── Anti Malware (Android only) ───────────────────────────────────────────

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

  // ── Anti Overlay ──────────────────────────────────────────────────────────

  @override
  Future<void> antiOverlayProtect({bool blockObscuredTouches = true}) =>
      _invoke(CShieldChannels.antiOverlayProtect, {'blockObscuredTouches': blockObscuredTouches});

  @override
  Future<void> antiOverlayUnprotect() => _invoke(CShieldChannels.antiOverlayUnprotect);

  // ── Behavioral Touch Guard ──────────────────────────────────────────────────

  @override
  Future<void> btgProtect({
    int? riskThreshold,
    bool blockWhenDetected = false,
    bool includeAccessibilitySignal = false,
  }) =>
      _invoke(CShieldChannels.btgProtect, {
        if (riskThreshold != null) 'riskThreshold': riskThreshold,
        'blockWhenDetected': blockWhenDetected,
        'includeAccessibilitySignal': includeAccessibilitySignal,
      });

  @override
  Future<void> btgUnprotect() => _invoke(CShieldChannels.btgUnprotect);

  // ── Anti Keylogger ──────────────────────────────────────────────────────────

  @override
  Future<void> antiKeyloggerConfigure({
    bool trustSystemKeyboards = true,
    List<String> trustedKeyboardPackages = const [],
    List<String> trustedAccessibilityPackages = const [],
  }) =>
      _invoke(CShieldChannels.antiKeyloggerConfigure, {
        'trustSystemKeyboards': trustSystemKeyboards,
        'trustedKeyboardPackages': trustedKeyboardPackages,
        'trustedAccessibilityPackages': trustedAccessibilityPackages,
      });

  @override
  Future<void> antiKeyloggerRunCheck() => _invoke(CShieldChannels.antiKeyloggerRunCheck);
}
