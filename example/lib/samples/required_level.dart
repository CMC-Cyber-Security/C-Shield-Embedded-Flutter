// SAMPLE: Sensitive routes handled by the interceptor
//
// Scenario: same server rules as sensitive_flow.dart (POST /payment and
// POST /transfer need trust level L4), but you would rather not call
// `ensureTrust` screen by screen. Map routes to trust levels once, where the
// client is built. Screens then make plain calls.
//
// Everything is in this file, in reading order:
//   1. requiredLevelFor() + buildDioWithRequiredLevels()  the part to copy.
//   2. RequiredLevelSample  a screen that makes plain calls.
//
// What the interceptor does for a mapped request:
//   1. starts raising trust in the background and sends the request at once;
//   2. if the server answers 403 CSHIELD_DEVICE_NOT_ALLOWED or
//      CSHIELD_TRUST_NOT_FRESH, raises trust with fresh proof and resends once.
//
// Difference from sensitive_flow.dart: nothing is blocked on the client. A
// device that cannot qualify finds out from the server's 403, after the
// request.
//
// Not available when the app was started without `cloudProjectNumber`.
//
// Guide: doc/aip.md, "Step 3".

import 'dart:convert';

import 'package:c_shield_embedded/c_shield_embedded.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';

import '../demo_config.dart'; // only constants: the demo server URL

/// The trust level each route needs, or `null` for ordinary routes.
TrustLevel? requiredLevelFor(RequestOptions options) {
  return switch (options.uri.path) {
    '/payment' || '/transfer' => TrustLevel.l4,
    _ => null, // no extra check, no Play Integrity cost
  };
}

Dio buildDioWithRequiredLevels() {
  final dio = Dio(BaseOptions(baseUrl: DemoConfig.baseUrl));
  dio.httpClientAdapter = CShieldSSL.createDioAdapter();
  dio.interceptors.add(CShieldDioInterceptor(
    dio: dio, // required here: the interceptor resends through it
    requiredLevel: requiredLevelFor,
  ));
  return dio;
}

class RequiredLevelSample extends StatefulWidget {
  const RequiredLevelSample({super.key});

  @override
  State<RequiredLevelSample> createState() => _RequiredLevelSampleState();
}

class _RequiredLevelSampleState extends State<RequiredLevelSample> {
  final Dio _dio = buildDioWithRequiredLevels();
  String _result = '';

  /// A plain call: the screen knows nothing about trust levels.
  Future<void> _post(String path) async {
    _show('Calling...');
    try {
      final before = await CShieldAttest.currentTrustLevel();
      final response = await _dio.post(path);
      final after = await CShieldAttest.currentTrustLevel();
      _show(
          'OK: ${response.data}\ntrust level: ${before.name} -> ${after.name}');
    } on DioException catch (e) {
      final sdkError = e.error;
      if (sdkError is CShieldException) {
        // For example playIntegrityNotConfigured: requiredLevel was set but
        // initialize() got no cloudProjectNumber.
        _show(
            'Refused by C-Shield: ${sdkError.code.name} (${sdkError.message})');
      } else {
        // Still 403 after the retry: the device cannot reach the level.
        final data = e.response?.data;
        final body = data is List<int>
            ? utf8.decode(data, allowMalformed: true)
            : '$data';
        _show('Refused by the server: HTTP ${e.response?.statusCode} $body');
      }
    }
  }

  void _show(String text) {
    if (mounted) setState(() => _result = text);
  }

  @override
  void dispose() {
    _dio.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Sensitive routes (requiredLevel)')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text(
              'Routes are mapped to trust levels in the interceptor. The calls '
              'below are plain calls; the interceptor raises trust and retries.'),
          const SizedBox(height: 16),
          FilledButton(
              onPressed: () => _post('/payment'),
              child: const Text('POST /payment')),
          FilledButton(
              onPressed: () => _post('/transfer'),
              child: const Text('POST /transfer')),
          const SizedBox(height: 16),
          Text(_result),
        ],
      ),
    );
  }
}
