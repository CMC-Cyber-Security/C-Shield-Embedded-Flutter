// SAMPLE: Sensitive flow. Raise trust before the call.
//
// Scenario: the server demands a higher trust level on some routes (payment,
// transfer, login). A device sits at L3 by default, so the app raises trust
// BEFORE the call and stops early when the device cannot qualify.
//
// Server rules used by the demo server:
//   POST /payment   needs trust level L4
//   POST /transfer  needs trust level L4 AND recent proof (maxTrustAgeSeconds)
//
// Everything is in this file, in reading order:
//   1. raiseTrustToL4()     the part to copy.
//   2. describe()           how to read an error.
//   3. SensitiveFlowSample  a screen with a payment and a transfer button.
//
// Cost: raising trust runs Play Integrity on Android (one quota unit).
// Not available when the app was started without `cloudProjectNumber`.
//
// Guide: doc/aip.md, "Step 3".

import 'dart:convert';

import 'package:c_shield_embedded/c_shield_embedded.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';

import '../demo_config.dart'; // only constants: the demo server URL

/// Raises the device to L4. Returns `null` when it qualified, otherwise the
/// message to show the user. Call it right before the sensitive API call.
///
/// Pass `requireFresh: true` for routes where the server also limits how old
/// the proof may be.
Future<String?> raiseTrustToL4({bool requireFresh = false}) async {
  final EnsureTrustResult result;
  try {
    result = await CShieldAttest.ensureTrust(
      TrustLevel.l4,
      requireFresh: requireFresh,
      timeoutMs: 20000, // Play Integrity can take a while
    );
  } on CShieldException catch (e) {
    // Thrown only for a setup mistake, for example playIntegrityNotConfigured:
    // initialize() got no cloudProjectNumber, so trust cannot be raised.
    return 'Cannot raise trust: ${e.code.name}';
  }
  switch (result) {
    case EnsureTrustResult.satisfied:
      return null; // go ahead
    case EnsureTrustResult.insufficient:
      // The device tried and cannot reach L4: block, or offer a reduced feature.
      return 'This device does not meet the required security level.';
    case EnsureTrustResult.offline:
      // Not a verdict on the device: let the user retry.
      return 'No internet connection. Check your network and try again.';
    case EnsureTrustResult.rateLimited:
    case EnsureTrustResult.timeout:
      // Transient. The current trust level is not lowered.
      return 'Could not verify the device right now. Try again later.';
    case EnsureTrustResult.unavailable:
      // Permanent: do not retry.
      return 'This device is not supported.';
  }
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

class SensitiveFlowSample extends StatefulWidget {
  const SensitiveFlowSample({super.key});

  @override
  State<SensitiveFlowSample> createState() => _SensitiveFlowSampleState();
}

class _SensitiveFlowSampleState extends State<SensitiveFlowSample> {
  // The same setup as basic_dio.dart: nothing extra for sensitive routes.
  late final Dio _dio = Dio(BaseOptions(baseUrl: DemoConfig.baseUrl))
    ..httpClientAdapter = CShieldSSL.createDioAdapter();
  String _result = '';

  @override
  void initState() {
    super.initState();
    _dio.interceptors.add(CShieldDioInterceptor(dio: _dio));
  }

  Future<void> _pay() async {
    _show('Raising trust...');
    final problem = await raiseTrustToL4();
    if (problem != null) return _show(problem); // stop before calling the API
    await _post('/payment');
  }

  Future<void> _transfer() async {
    _show('Raising trust with fresh proof...');
    final problem = await raiseTrustToL4(requireFresh: true);
    if (problem != null) return _show(problem);
    await _post('/transfer');
  }

  /// Skips raiseTrustToL4() on purpose, to show what the server answers when
  /// trust is too low or too old: 403 with CSHIELD_DEVICE_NOT_ALLOWED or
  /// CSHIELD_TRUST_NOT_FRESH.
  Future<void> _transferWithoutRaising() => _post('/transfer');

  Future<void> _post(String path) async {
    try {
      final response = await _dio.post(path);
      final trust = await CShieldAttest.currentTrustLevel();
      _show('OK: ${response.data}\ntrust level is now ${trust.name}');
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
      appBar: AppBar(title: const Text('Sensitive flow (ensureTrust)')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text(
              'Raise trust to L4 before a sensitive call, and stop on the client '
              'when the device cannot reach it.'),
          const SizedBox(height: 16),
          FilledButton(
              onPressed: _pay,
              child: const Text('Payment: raise to L4, then POST /payment')),
          FilledButton(
            onPressed: _transfer,
            child: const Text(
                'Transfer: raise to L4 with fresh proof, then POST /transfer'),
          ),
          FilledButton.tonal(
            onPressed: _transferWithoutRaising,
            child:
                const Text('POST /transfer without raising trust (expect 403)'),
          ),
          const SizedBox(height: 16),
          Text(_result),
        ],
      ),
    );
  }
}
