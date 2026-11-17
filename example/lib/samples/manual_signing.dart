// SAMPLE: Manual signing (advanced)
//
// Scenario: you cannot use the interceptors, for example with an HTTP client
// the SDK has no adapter for. You sign, send, verify and handle token expiry
// yourself with `CShieldAIP`.
//
// Prefer the interceptors whenever they fit: [signedPost] below is roughly
// what they do for you.
//
// Guide: doc/aip.md, "Advanced: manual signing".

import 'dart:convert';
import 'dart:typed_data';

import 'package:c_shield_embedded/c_shield_embedded.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../demo_config.dart'; // only constants: the demo server URL

/// Signs and sends a JSON POST, verifies the response, and retries once if the
/// server reports an expired access token.
Future<http.Response> signedPost(
  http.Client client,
  Uri uri,
  Map<String, dynamic> json, {
  bool isRetry = false,
}) async {
  final body = Uint8List.fromList(utf8.encode(jsonEncode(json)));

  // 1. Sign. The proof is single-use and valid for 30 seconds: send it right
  //    away and never reuse it.
  final proofHeaders = await CShieldAIP.signRequest(
    method: 'POST',
    path: uri.path,
    query: uri.query, // '' when there is no query string
    body: body,
    contentType: 'application/json',
  );

  // 2. Send exactly the bytes that were signed.
  final response = await client.post(
    uri,
    headers: {'Content-Type': 'application/json', ...proofHeaders},
    body: body,
  );

  // 3. Verify, with the same path and query that were signed. Throws a
  //    CShieldException if the response was tampered with.
  await CShieldAIP.verifyResponse(
    statusCode: response.statusCode,
    path: uri.path,
    query: uri.query,
    headers: response.headers,
    body: response.bodyBytes,
  );

  // 4. Token expired on the server: refresh it and resend once.
  if (!isRetry &&
      CShieldAIP.isInvalidAccessToken(
          response.statusCode, response.bodyBytes) &&
      await CShieldAttest.forceRefresh()) {
    return signedPost(client, uri, json, isRetry: true);
  }
  return response;
}

class ManualSigningSample extends StatefulWidget {
  const ManualSigningSample({super.key});

  @override
  State<ManualSigningSample> createState() => _ManualSigningSampleState();
}

class _ManualSigningSampleState extends State<ManualSigningSample> {
  // Pinned, but with no C-Shield interceptor: signing is done by hand.
  final http.Client _client = CShieldSSL.createIOClient();
  String _result = '';

  Future<void> _verifyOtp() async {
    _show('Calling...');
    try {
      final response = await signedPost(
        _client,
        Uri.parse('${DemoConfig.baseUrl}/verify-otp'),
        {'otp': '123456'},
      );
      _show('HTTP ${response.statusCode}: ${response.body}');
    } on CShieldException catch (e) {
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
      appBar: AppBar(title: const Text('Manual signing')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text(
              'Sign, send, verify and refresh by hand with CShieldAIP, for '
              'clients the interceptors do not cover.'),
          const SizedBox(height: 16),
          FilledButton(
              onPressed: _verifyOtp,
              child: const Text('Signed POST /verify-otp')),
          const SizedBox(height: 16),
          Text(_result),
        ],
      ),
    );
  }
}
