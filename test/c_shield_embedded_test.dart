import 'dart:typed_data';

import 'package:c_shield_embedded/src/api/attest/c_shield_state.dart';
import 'package:c_shield_embedded/src/api/attest/ensure_trust_result.dart';
import 'package:c_shield_embedded/src/api/attest/trust_level.dart';
import 'package:c_shield_embedded/src/api/event/c_shield_event.dart';
import 'package:c_shield_embedded/src/api/malware/models.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:c_shield_embedded/src/internal/platform/c_shield_embedded_platform_interface.dart';
import 'package:c_shield_embedded/src/internal/platform/c_shield_embedded_method_channel.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

class MockCShieldEmbeddedPlatform with MockPlatformInterfaceMixin implements CShieldEmbeddedPlatform {
  @override
  Future<void> aipVerify({required String payload, required String signature}) {
    // TODO: implement aipVerify
    throw UnimplementedError();
  }

  @override
  Future<void> initialize({required String license}) {
    // TODO: implement initialize
    throw UnimplementedError();
  }

  @override
  Future<bool> sslCheckServerTrusted({required String certDerBase64, required String host}) {
    // TODO: implement sslCheckServerTrusted
    throw UnimplementedError();
  }

  @override
  Future<void> sslConfigure({required Map<String, List<String>> pinsByHost, bool allowRuntimeUpdates = false}) {
    // TODO: implement sslConfigure
    throw UnimplementedError();
  }

  @override
  Future<Map<Object?, Object?>> sslHttpRequest({
    required String method,
    required String url,
    required Map<String, String> headers,
    Uint8List? body,
    int? connectTimeoutMs,
    int? receiveTimeoutMs,
    bool followRedirects = true,
  }) {
    // TODO: implement sslHttpRequest
    throw UnimplementedError();
  }

  @override
  Future<bool> sslIsConfigured() {
    // TODO: implement sslIsConfigured
    throw UnimplementedError();
  }

  @override
  Future<void> sslUpdatePins({required List<String> pins, required String hostname}) {
    // TODO: implement sslUpdatePins
    throw UnimplementedError();
  }

  @override
  Future<Map<Object, Object>> aipSignRequest(
      {required String method,
      required String path,
      required String canonicalQuery,
      required int timestampSec,
      required String bodyHashHex}) {
    // TODO: implement aipSignRequest
    throw UnimplementedError();
  }

  @override
  Future<ScannedPackage> analyzeApkFile(String filePath) {
    // TODO: implement analyzeApkFile
    throw UnimplementedError();
  }

  @override
  Future<ScannedPackage> analyzeInstalledApp(String packageName) {
    // TODO: implement analyzeInstalledApp
    throw UnimplementedError();
  }

  @override
  Future<DeviceScanResult> scanDevice() {
    // TODO: implement scanDevice
    throw UnimplementedError();
  }

  @override
  Future<void> stopScan() {
    // TODO: implement stopScan
    throw UnimplementedError();
  }

  @override
  // TODO: implement licenseEvents
  Stream<CShieldEvent> get events => throw UnimplementedError();

  @override
  Future<bool> aipForceRefresh({int timeoutMs = 5000}) {
    // TODO: implement aipForceRefresh
    throw UnimplementedError();
  }

  @override
  Future<CShieldState> attestState() {
    // TODO: implement attestState
    throw UnimplementedError();
  }

  @override
  Future<String?> attestLastError() {
    // TODO: implement attestLastError
    throw UnimplementedError();
  }

  @override
  Future<CShieldState> attestAwaitReady({int timeoutMs = 8000}) {
    // TODO: implement attestAwaitReady
    throw UnimplementedError();
  }

  @override
  Future<TrustLevel> attestCurrentTrustLevel() {
    // TODO: implement attestCurrentTrustLevel
    throw UnimplementedError();
  }

  @override
  Future<EnsureTrustResult> attestEnsureTrust({
    required TrustLevel minLevel,
    bool requireFresh = false,
    int timeoutMs = 15000,
  }) {
    // TODO: implement attestEnsureTrust
    throw UnimplementedError();
  }
}

void main() {
  final CShieldEmbeddedPlatform initialPlatform = CShieldEmbeddedPlatform.instance;

  test('$MethodChannelCShieldEmbedded is the default instance', () {
    expect(initialPlatform, isInstanceOf<MethodChannelCShieldEmbedded>());
  });
}
