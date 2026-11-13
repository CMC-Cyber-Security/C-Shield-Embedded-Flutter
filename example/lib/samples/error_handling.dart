// SAMPLE: Handling errors
//
// Scenario: turn whatever goes wrong into a message for the user.
//
// Two different things can go wrong:
//   A. The SDK refused: a `CShieldException` with a typed `code`. Thrown
//      directly by SDK calls and by the `http` interceptor; wrapped in
//      `DioException.error` by the Dio interceptor.
//   B. The server refused: an ordinary HTTP error (401 / 403) whose JSON body
//      carries a C-Shield code such as CSHIELD_DEVICE_NOT_ALLOWED.
//
// Everything is in this file, in reading order:
//   1. messageFor()         every SDK error code -> user message. Copy it.
//   2. serverCode()         reads the C-Shield code from a server rejection.
//   3. ErrorHandlingSample  a screen that provokes A and B.
//
// Guide: doc/aip.md, "Step 4", and doc/events-and-errors.md.

import 'dart:convert';

import 'package:c_shield_embedded/c_shield_embedded.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';

import '../demo_config.dart'; // only constants: the demo server URL and pins

/// A user-facing message for every SDK error code.
///
/// The `switch` is exhaustive: a code added by a future SDK version becomes a
/// compile error here instead of a silently unhandled case.
String messageFor(CShieldException e) {
  return switch (e.code) {
    // Attestation was not ready when the request had to be signed.
    CShieldErrorCode.notReady => e.retryable == true
        ? 'Security is still starting up. Please try again in a moment.'
        : 'This device is not supported (${e.message}).',

    // Transport security: stop and report, never fall back to an insecure call.
    CShieldErrorCode.sslPinMismatch =>
      'Secure connection could not be verified.',
    CShieldErrorCode.aipInvalidSignature =>
      'The server response could not be verified.',
    CShieldErrorCode.aipMissingHeader =>
      'The server response could not be verified.',
    CShieldErrorCode.aipDetectProxyCA =>
      'A proxy was detected on this network.',

    // Almost always a wrong device clock.
    CShieldErrorCode.aipTimestampExpired =>
      'Please check the date and time on your device.',

    // Integration mistakes: these should never reach a released app.
    CShieldErrorCode.notInitialized =>
      'Developer error: call CShieldEmbedded.initialize() first.',
    CShieldErrorCode.sslNotConfigured =>
      'Developer error: pinning is not configured (${e.message}).',
    CShieldErrorCode.playIntegrityNotConfigured =>
      'Developer error: pass cloudProjectNumber to initialize() to raise trust.',
    CShieldErrorCode.invalidArgument => 'Developer error: ${e.message}',
    CShieldErrorCode.unsupportedPlatform =>
      'This feature is not available on this platform.',

    // Everything else.
    CShieldErrorCode.aipSigningFailed ||
    CShieldErrorCode.nativeError =>
      'Security error: ${e.message}',
  };
}

/// Reads the server's `code` from a failed response, for example
/// `CSHIELD_DEVICE_NOT_ALLOWED`. Returns `null` when there is none.
///
/// The body of a failed request arrives as raw bytes: the interceptor reads
/// responses as bytes to verify their signature.
String? serverCode(DioException e) {
  final data = e.response?.data;
  try {
    final json = data is List<int> ? jsonDecode(utf8.decode(data)) : data;
    return json is Map ? json['code'] as String? : null;
  } catch (_) {
    return null; // not JSON
  }
}

class ErrorHandlingSample extends StatefulWidget {
  const ErrorHandlingSample({super.key});

  @override
  State<ErrorHandlingSample> createState() => _ErrorHandlingSampleState();
}

class _ErrorHandlingSampleState extends State<ErrorHandlingSample> {
  // The same setup as basic_dio.dart.
  late final Dio _dio = Dio(BaseOptions(baseUrl: DemoConfig.baseUrl))
    ..httpClientAdapter = CShieldSSL.createDioAdapter();
  String _result = '';

  @override
  void initState() {
    super.initState();
    _dio.interceptors.add(CShieldDioInterceptor(dio: _dio));
  }

  /// The catch block to copy: one `catch` covers A and B.
  ///
  /// POST /transfer needs fresh L4 proof and this call does not raise trust,
  /// so the server normally rejects it with a 403 (case B).
  Future<void> _requestError() async {
    try {
      final response = await _dio.post('/transfer');
      _show('No error: ${response.data}');
    } on DioException catch (e) {
      final sdkError = e.error;
      if (sdkError is CShieldException) {
        // A. The SDK refused to send the request or rejected the response.
        _show('SDK error: ${sdkError.code.name}\n'
            'Message for the user: ${messageFor(sdkError)}');
      } else {
        // B. The server answered with an error.
        _show('Server rejection: HTTP ${e.response?.statusCode}, '
            'code: ${serverCode(e) ?? 'none'}');
      }
    }
  }

  /// Case A outside a request: an SDK call throws a `CShieldException`
  /// directly.
  ///
  /// The pin set is sealed after configuration, so `updatePins` is a cheap,
  /// harmless way to provoke one (`sslNotConfigured`).
  Future<void> _sdkErrorDirect() async {
    try {
      await CShieldSSL.updatePins(
          pins: DemoConfig.pins, hostname: DemoConfig.pinnedHost);
      _show('No error: the pin set allows runtime updates.');
    } on CShieldException catch (e) {
      _show(
          'SDK error: ${e.code.name}\nMessage for the user: ${messageFor(e)}');
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
      appBar: AppBar(title: const Text('Error handling')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text(
              'SDK errors are CShieldException (inside DioException with Dio). '
              'Server rejections are HTTP errors with a C-Shield code in the body.'),
          const SizedBox(height: 16),
          FilledButton(
              onPressed: _requestError,
              child: const Text('Error from a request (POST /transfer)')),
          FilledButton.tonal(
              onPressed: _sdkErrorDirect,
              child: const Text('SDK error from a direct call')),
          const SizedBox(height: 16),
          Text(_result),
        ],
      ),
    );
  }
}
