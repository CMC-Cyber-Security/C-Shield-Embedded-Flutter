// SAMPLE: Sign only some requests
//
// Scenario: the same Dio instance talks to endpoints your server protects with
// C-Shield and to endpoints it does not (public config, health checks, a
// third-party API).
//
// Everything is in this file, in reading order:
//   1. isProtected() + buildSelectiveDio()  the part to copy.
//   2. SelectiveSigningSample  a screen that calls one endpoint of each kind
//      and shows whether the request was signed.
//
// A request that `signWhen` rejects is sent unsigned and its response is not
// verified.
//
// Guide: doc/aip.md, "Signing only some requests".

import 'package:c_shield_embedded/c_shield_embedded.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';

import '../demo_config.dart'; // only constants: the demo server URL

/// The paths the server protects with C-Shield. Everything else is left alone.
bool isProtected(RequestOptions options) {
  const protectedPaths = {'/verify-otp', '/payment', '/transfer'};
  return protectedPaths.contains(options.uri.path);
}

Dio buildSelectiveDio() {
  final dio = Dio(BaseOptions(baseUrl: DemoConfig.baseUrl));
  dio.httpClientAdapter = CShieldSSL.createDioAdapter();
  dio.interceptors.add(CShieldDioInterceptor(dio: dio, signWhen: isProtected));
  return dio;
}

class SelectiveSigningSample extends StatefulWidget {
  const SelectiveSigningSample({super.key});

  @override
  State<SelectiveSigningSample> createState() => _SelectiveSigningSampleState();
}

class _SelectiveSigningSampleState extends State<SelectiveSigningSample> {
  final Dio _dio = buildSelectiveDio();
  String _result = '';

  Future<void> _call(String method, String path) async {
    _show('Calling...');
    try {
      final response = await _dio.request<dynamic>(
        path,
        data: method == 'POST' ? {'otp': '123456'} : null,
        options: Options(method: method),
      );
      // A signed request carries the `cs-proof` header.
      final signed = response.requestOptions.headers.containsKey('cs-proof');
      _show('$method $path -> HTTP ${response.statusCode}\n'
          '${signed ? 'signed and verified' : 'sent unsigned, not verified'}');
    } on DioException catch (e) {
      final sdkError = e.error;
      _show(sdkError is CShieldException
          ? 'Refused by C-Shield: ${sdkError.code.name} (${sdkError.message})'
          : 'HTTP ${e.response?.statusCode}');
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
      appBar: AppBar(title: const Text('Selective signing')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text(
              'signWhen decides per request. Protected paths are signed and '
              'verified; any other request passes through untouched.'),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: () => _call('POST', '/verify-otp'),
            child: const Text('POST /verify-otp (protected)'),
          ),
          FilledButton.tonal(
              onPressed: () => _call('GET', '/'),
              child: const Text('GET / (not protected)')),
          const SizedBox(height: 16),
          Text(_result),
        ],
      ),
    );
  }
}
