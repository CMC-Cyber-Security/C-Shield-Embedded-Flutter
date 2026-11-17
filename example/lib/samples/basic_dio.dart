// SAMPLE: Basic setup with Dio (start here)
//
// Scenario: every call to your API is pinned, signed, and its response
// verified. This is all most apps need.
//
// Everything is in this file, in reading order:
//   1. buildProtectedDio()  the setup. This is the part to copy.
//   2. describe()           how to read an error.
//   3. BasicDioSample       a screen that makes one call.
//
// Before this runs, main() has called `CShieldEmbedded.initialize()` and
// `CShieldSSL.configureHosts()` (see main.dart).
//
// Guide: doc/aip.md, "Step 1".

import 'dart:convert';

import 'package:c_shield_embedded/c_shield_embedded.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';

import '../demo_config.dart'; // only constants: the demo server URL

/// Builds the one Dio instance the app uses for its protected API.
/// Create it once and reuse it.
Dio buildProtectedDio() {
  final dio = Dio(BaseOptions(baseUrl: DemoConfig.baseUrl));

  // TLS pinning: requests to the pinned hosts are performed natively.
  dio.httpClientAdapter = CShieldSSL.createDioAdapter();

  // Signs every request and verifies every response. Passing `dio` lets the
  // interceptor resend a request after it refreshes an expired token.
  dio.interceptors.add(CShieldDioInterceptor(dio: dio));

  return dio;
}

/// Turns a failed Dio call into one line of text.
///
/// - The SDK refused (not ready, pin mismatch, tampered response): `e.error`
///   is a [CShieldException].
/// - The server refused (401 / 403): `e.response` is set. Its body arrives as
///   raw bytes, because the interceptor reads responses as bytes to verify
///   their signature.
String describe(DioException e) {
  final sdkError = e.error;
  if (sdkError is CShieldException) {
    return 'Refused by C-Shield: ${sdkError.code.name} (${sdkError.message})';
  }
  final data = e.response?.data;
  final body =
      data is List<int> ? utf8.decode(data, allowMalformed: true) : '$data';
  return 'Refused by the server: HTTP ${e.response?.statusCode} $body';
}

class BasicDioSample extends StatefulWidget {
  const BasicDioSample({super.key});

  @override
  State<BasicDioSample> createState() => _BasicDioSampleState();
}

class _BasicDioSampleState extends State<BasicDioSample> {
  final Dio _dio = buildProtectedDio();
  String _result = '';

  /// An ordinary Dio call. Nothing in it mentions the SDK: the interceptor
  /// signs the request and verifies the response.
  Future<void> _verifyOtp() async {
    _show('Calling...');
    try {
      final response = await _dio.post('/verify-otp', data: {'otp': '123456'});
      _show('OK: ${response.data}');
    } on DioException catch (e) {
      _show(describe(e));
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
      appBar: AppBar(title: const Text('Basic setup (Dio)')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text(
              'One Dio instance with pinning and the C-Shield interceptor. '
              'The call below is a normal Dio call.'),
          const SizedBox(height: 16),
          FilledButton(
              onPressed: _verifyOtp, child: const Text('POST /verify-otp')),
          const SizedBox(height: 16),
          Text(_result),
        ],
      ),
    );
  }
}
