import 'dart:convert';

import 'package:c_shield_embedded/c_shield_embedded.dart';
import 'package:c_shield_embedded/src/internal/platform/c_shield_embedded_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

/// Minimal platform fake: signing always succeeds; refresh / ensureTrust are counted.
class _FakePlatform extends CShieldEmbeddedPlatform with MockPlatformInterfaceMixin {
  int forceRefreshCalls = 0;
  int ensureTrustFreshCalls = 0;

  @override
  Future<Map<Object?, Object?>> aipSignRequest({
    required String method,
    required String path,
    required String canonicalQuery,
    required int timestampSec,
    required String bodyHashHex,
  }) async =>
      {'cs-proof': 'proof'};

  @override
  Future<bool> aipForceRefresh({int timeoutMs = 5000}) async {
    forceRefreshCalls++;
    return true;
  }

  @override
  Future<EnsureTrustResult> attestEnsureTrust({
    required TrustLevel minLevel,
    bool requireFresh = false,
    int timeoutMs = 15000,
  }) async {
    if (requireFresh) ensureTrustFreshCalls++;
    return EnsureTrustResult.satisfied;
  }
}

void main() {
  late _FakePlatform platform;

  setUp(() {
    platform = _FakePlatform();
    CShieldEmbeddedPlatform.instance = platform;
  });

  /// A client that answers [first] once, then 200 `ok`; counts the requests it receives.
  (http.Client, List<http.Request>) clientAnswering(http.Response first) {
    final seen = <http.Request>[];
    final client = MockClient((request) async {
      seen.add(request);
      return seen.length == 1 ? first : http.Response('ok', 200);
    });
    return (client, seen);
  }

  group('CShieldInterceptor with verifyResponses: false', () {
    test('refreshes the token and retries once on 401 CSHIELD_INVALID_ACCESS_TOKEN', () async {
      final (inner, seen) =
          clientAnswering(http.Response(jsonEncode({'code': 'CSHIELD_INVALID_ACCESS_TOKEN'}), 401));
      final client = CShieldInterceptor(inner: inner, verifyResponses: false);

      final response = await client.get(Uri.parse('https://api.example.com/data'));

      expect(response.statusCode, 200);
      expect(seen.length, 2);
      expect(platform.forceRefreshCalls, 1);
    });

    test('raises trust and retries once on a trust 403 when requiredLevel is set', () async {
      final (inner, seen) =
          clientAnswering(http.Response(jsonEncode({'code': 'CSHIELD_DEVICE_NOT_ALLOWED'}), 403));
      final client = CShieldInterceptor(
        inner: inner,
        verifyResponses: false,
        requiredLevel: (_) => TrustLevel.l4,
      );

      final response = await client.get(Uri.parse('https://api.example.com/payment'));

      expect(response.statusCode, 200);
      expect(seen.length, 2);
      expect(platform.ensureTrustFreshCalls, 1);
    });

    test('returns an unrelated 401 untouched, with its body intact', () async {
      final (inner, seen) = clientAnswering(http.Response('nope', 401));
      final client = CShieldInterceptor(inner: inner, verifyResponses: false);

      final response = await client.get(Uri.parse('https://api.example.com/data'));

      expect(response.statusCode, 401);
      expect(response.body, 'nope');
      expect(seen.length, 1);
      expect(platform.forceRefreshCalls, 0);
    });
  });
}
