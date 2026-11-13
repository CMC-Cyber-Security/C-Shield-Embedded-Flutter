import 'dart:async';
import 'dart:typed_data';

import 'package:c_shield_embedded/src/internal/platform/c_shield_embedded_platform_interface.dart';
import 'package:dio/dio.dart';
import 'package:dio/io.dart';

/// Dio [HttpClientAdapter] that performs the HTTPS requests for pinned hosts
/// entirely on the **native** side (OkHttp on Android, URLSession on iOS).
///
/// Why: `dart:io` only ever exposes the leaf certificate, so pure-Dart pinning
/// can only match the leaf. By delegating the transport to native — where the
/// full certificate chain is available — the SDK matches pins against the whole
/// chain, exactly like the standalone Android and iOS SDKs. This lets you pin a
/// stable intermediate CA so the app survives leaf certificate rotation.
///
/// Only HTTPS requests to a host that matches one of the configured host
/// patterns are routed to native; every other request is transparently
/// delegated to a standard [IOHttpClientAdapter], so unpinned traffic behaves
/// exactly as before.
///
/// Buffered (non-streaming): the request body is collected in full before the
/// call and the response body is returned in full. This covers typical REST/JSON
/// usage. For large uploads/downloads or SSE, use a non-pinned Dio instance.
/// A Dio `CancelToken` does not cancel the native request.
///
/// Obtain an instance with `CShieldSSL.createDioAdapter()`.
class CShieldNativeHttpAdapter implements HttpClientAdapter {
  /// Creates an adapter that routes requests matching [hostPatterns] to
  /// native.
  CShieldNativeHttpAdapter({required Set<String> hostPatterns})
      // Normalize like the native PinningConfig (lowercase, no trailing dot), so that
      // `API.Example.com` in the configuration still routes requests for `api.example.com`
      // to native.
      : _hostPatterns = hostPatterns.map(_normalize).toSet(),
        _fallback = IOHttpClientAdapter();

  /// Every pinned host pattern (exact / `*.` / `**.`). An HTTPS request matching ANY of them
  /// goes to native; everything else is delegated to [_fallback].
  final Set<String> _hostPatterns;
  final HttpClientAdapter _fallback;

  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream, Future<dynamic>? cancelFuture) async {
    final uri = options.uri;
    final isPinnedHost = uri.isScheme('https') && _hostPatterns.any((p) => _hostMatches(uri.host, p));
    if (!isPinnedHost) {
      return _fallback.fetch(options, requestStream, cancelFuture);
    }

    final body = requestStream == null ? null : await _collectBytes(requestStream);

    final headers = <String, String>{};
    options.headers.forEach((key, value) {
      if (value != null) headers[key] = '$value';
    });

    final result = await CShieldEmbeddedPlatform.instance.sslHttpRequest(
      method: options.method,
      url: uri.toString(),
      headers: headers,
      body: body,
      connectTimeoutMs: options.connectTimeout?.inMilliseconds,
      receiveTimeoutMs: options.receiveTimeout?.inMilliseconds,
      followRedirects: options.followRedirects,
    );

    final statusCode = (result['statusCode'] as num?)?.toInt() ?? 0;
    final reasonPhrase = result['reasonPhrase'] as String?;
    final rawBody = result['body'];
    final bodyBytes = rawBody is Uint8List ? rawBody : Uint8List.fromList((rawBody as List?)?.cast<int>() ?? const <int>[]);

    return ResponseBody.fromBytes(bodyBytes, statusCode, headers: _decodeHeaders(result['headers']), statusMessage: reasonPhrase);
  }

  @override
  void close({bool force = false}) => _fallback.close(force: force);

  /// Lowercases a host and strips trailing dots, like the native `PinningConfig`.
  static String _normalize(String host) {
    var h = host.trim().toLowerCase();
    while (h.endsWith('.')) {
      h = h.substring(0, h.length - 1);
    }
    return h;
  }

  /// Matches a host against a pattern the same way the native `PinningConfig` does: exact,
  /// `*.` (one level), `**.` (any depth).
  static bool _hostMatches(String rawHost, String pattern) {
    final host = _normalize(rawHost);
    if (pattern == host) return true;
    if (pattern.startsWith('**.')) {
      final apex = pattern.substring(3);
      return host == apex || host.endsWith('.$apex');
    }
    if (pattern.startsWith('*.')) {
      final suffix = pattern.substring(2);
      if (!host.endsWith('.$suffix')) return false;
      final sub = host.substring(0, host.length - suffix.length - 1);
      return sub.isNotEmpty && !sub.contains('.');
    }
    return false;
  }

  static Future<Uint8List> _collectBytes(Stream<Uint8List> stream) async {
    final chunks = <int>[];
    await for (final chunk in stream) {
      chunks.addAll(chunk);
    }
    return Uint8List.fromList(chunks);
  }

  /// Native returns `Map<String, List<String>>` (possibly typed as
  /// `Map<Object?, Object?>` across the channel). Normalize to Dio's shape.
  static Map<String, List<String>> _decodeHeaders(Object? raw) {
    final out = <String, List<String>>{};
    if (raw is Map) {
      raw.forEach((key, value) {
        if (key == null) return;
        if (value is List) {
          out['$key'] = value.map((e) => '$e').toList();
        } else if (value != null) {
          out['$key'] = ['$value'];
        }
      });
    }
    return out;
  }
}
