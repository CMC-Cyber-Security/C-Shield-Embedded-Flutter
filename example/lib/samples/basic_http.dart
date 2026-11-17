// SAMPLE: Basic setup with the `http` package
//
// Scenario: the app uses `package:http` instead of Dio.
//
// Everything is in this file, in reading order:
//   1. buildProtectedClient()  the setup. This is the part to copy.
//   2. BasicHttpSample         a screen that makes one call and reads errors.
//
// Trade-off: signing and verification are identical to Dio, but pinning on
// this path is weaker. It checks the leaf certificate only, and not at all for
// a certificate that chains to a CA the device trusts. Prefer Dio for
// sensitive APIs. See doc/ssl-pinning.md, "Which path to use".
//
// Guide: doc/aip.md, "Step 1".

import 'dart:convert';

import 'package:c_shield_embedded/c_shield_embedded.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../demo_config.dart'; // only constants: the demo server URL

/// Builds the one client the app uses for its protected API.
/// Create it once and reuse it.
http.Client buildProtectedClient() {
  return CShieldInterceptor(
    // The inner client does the pinning; leave it out to sign without pinning.
    inner: CShieldSSL.createIOClient(),
  );
}

class BasicHttpSample extends StatefulWidget {
  const BasicHttpSample({super.key});

  @override
  State<BasicHttpSample> createState() => _BasicHttpSampleState();
}

class _BasicHttpSampleState extends State<BasicHttpSample> {
  final http.Client _client = buildProtectedClient();
  String _result = '';

  /// An ordinary `http` call. The client signs the request and verifies the
  /// response.
  Future<void> _verifyOtp() async {
    _show('Calling...');
    try {
      final response = await _client.post(
        Uri.parse('${DemoConfig.baseUrl}/verify-otp'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'otp': '123456'}),
      );
      // With `http`, a 401 / 403 from the server is a normal response.
      _show(response.statusCode == 200
          ? 'OK: ${response.body}'
          : 'Refused by the server: HTTP ${response.statusCode} ${response.body}');
    } on CShieldException catch (e) {
      // The SDK refused (not ready, pin mismatch, tampered response). With
      // `http` it is thrown directly; Dio wraps it in a DioException.
      _show('Refused by C-Shield: ${e.code.name} (${e.message})');
    }
  }

  void _show(String text) {
    if (mounted) setState(() => _result = text);
  }

  @override
  void dispose() {
    _client.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Basic setup (http)')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text(
              'CShieldInterceptor is an http.Client. Wrap a pinned client with it '
              'and use it wherever you use http.Client.'),
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
