// SAMPLE: App start. Wait until the SDK is ready.
//
// Scenario: `initialize()` returns at once, but the SDK needs a moment more
// (typically a second or two on first launch) before it can sign requests. A
// request sent during that moment is refused with `notReady`. So the app
// waits on its splash screen.
//
// Everything is in this file, in reading order:
//   1. waitUntilReady()        call it from your splash screen. The part to copy.
//   2. buildDioThatWaits()     fallback for apps that cannot wait at startup.
//   3. StartupReadinessSample  a screen that runs both and shows the live state.
//
// Guide: doc/aip.md, "Step 2".

import 'dart:convert';

import 'package:c_shield_embedded/c_shield_embedded.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';

import '../demo_config.dart'; // only constants: the demo server URL

/// What the splash screen should do next.
enum SplashOutcome { goHome, offerRetry, deviceNotSupported }

/// Call this from your splash screen, after `initialize()`, before navigating.
///
/// It does not start anything: it waits for the work `initialize()` started,
/// and returns immediately if that has already finished.
Future<SplashOutcome> waitUntilReady() async {
  final state = await CShieldAttest.awaitReady(timeoutMs: 8000);
  switch (state) {
    case CShieldState.ready:
    case CShieldState.degraded:
      // Requests can be signed. (`degraded` = low trust level; requests are
      // still signed and the server decides which routes to allow.)
      return SplashOutcome.goHome;
    case CShieldState.initializing:
      // 8 seconds were not enough (slow or no network). The SDK keeps trying
      // in the background: show "retry" and call waitUntilReady() again.
      return SplashOutcome.offerRetry;
    case CShieldState.unavailable:
      // Permanent: this device or build cannot be attested. Do not retry.
      // `CShieldAttest.lastError()` gives the reason.
      return SplashOutcome.deviceNotSupported;
  }
}

/// Fallback, only for apps that cannot wait at startup.
///
/// `onNotReady` tells the interceptor what to do with a request that arrives
/// while the SDK is still not ready:
///   - OnNotReady.failFast (default): do not send it, throw `notReady`.
///   - OnNotReady.blockRetry: hold it for up to 2 seconds until the SDK is
///     ready, then sign and send it.
///   - OnNotReady.passThrough: send it unsigned (unprotected endpoints only).
Dio buildDioThatWaits() {
  final dio = Dio(BaseOptions(baseUrl: DemoConfig.baseUrl));
  dio.httpClientAdapter = CShieldSSL.createDioAdapter();
  dio.interceptors.add(
    CShieldDioInterceptor(dio: dio, onNotReady: OnNotReady.blockRetry),
  );
  return dio;
}

class StartupReadinessSample extends StatefulWidget {
  const StartupReadinessSample({super.key});

  @override
  State<StartupReadinessSample> createState() => _StartupReadinessSampleState();
}

class _StartupReadinessSampleState extends State<StartupReadinessSample> {
  final Dio _dio = buildDioThatWaits();
  String _result = '';

  /// What a splash screen does.
  Future<void> _runSplashLogic() async {
    _show('Waiting for the SDK...');
    switch (await waitUntilReady()) {
      case SplashOutcome.goHome:
        _show('Ready: navigate to the home screen.');
      case SplashOutcome.offerRetry:
        _show('Not ready after 8 seconds: show a "retry" button.');
      case SplashOutcome.deviceNotSupported:
        _show('Device not supported: ${await CShieldAttest.lastError()}');
    }
  }

  /// A request through the Dio built with OnNotReady.blockRetry.
  Future<void> _sendRequest() async {
    _show('Calling...');
    try {
      final response = await _dio.post('/verify-otp', data: {'otp': '123456'});
      _show('OK: ${response.data}');
    } on DioException catch (e) {
      final sdkError = e.error;
      if (sdkError is CShieldException) {
        // `notReady` with retryable == true: still starting, try again.
        // `notReady` with retryable == false: the device is not supported.
        _show('Refused by C-Shield: ${sdkError.code.name}, '
            'retryable: ${sdkError.retryable}');
      } else {
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
      appBar: AppBar(title: const Text('App start and readiness')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text(
              'The SDK needs a moment after initialize() before it can sign '
              'requests. A splash screen waits for it with awaitReady().'),
          const SizedBox(height: 16),

          // Live state, for a status banner or a debug screen. The stream
          // emits the current state as soon as you subscribe.
          StreamBuilder<AttestStateChanged>(
            stream: CShieldAttest.stateChanges,
            builder: (context, snapshot) {
              final event = snapshot.data;
              return Text(event == null
                  ? 'state: ...'
                  : 'state: ${event.state.name}, trust: ${event.trustLevel.name}, '
                      'lastError: ${event.lastError ?? 'none'}');
            },
          ),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: _runSplashLogic,
            child: const Text('Run the splash logic (awaitReady)'),
          ),
          FilledButton.tonal(
            onPressed: _sendRequest,
            child: const Text('Send a request (OnNotReady.blockRetry)'),
          ),
          const SizedBox(height: 16),
          Text(_result),
        ],
      ),
    );
  }
}
