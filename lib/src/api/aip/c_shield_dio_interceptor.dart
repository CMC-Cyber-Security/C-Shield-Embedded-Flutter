import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';

import '../../internal/aip/aip_normalizer.dart';
import '../attest/c_shield_attest.dart';
import '../attest/ensure_trust_result.dart';
import '../attest/trust_level.dart';
import '../exceptions/c_shield_exception.dart';
import 'c_shield_aip.dart';
import 'on_not_ready.dart';

/// A Dio [Interceptor] that automatically signs every outgoing request
/// and verifies every incoming response using CShield AIP.
///
/// Add it once when creating your Dio instance:
/// ```dart
/// final dio = Dio(BaseOptions(baseUrl: 'https://api.example.com'));
/// dio.interceptors.add(CShieldDioInterceptor(dio: dio));
/// ```
///
/// Combined with SSL pinning:
/// ```dart
/// dio.httpClientAdapter = CShieldSSL.createDioAdapter();
/// dio.interceptors.add(CShieldDioInterceptor(dio: dio));
/// ```
///
/// Pass the owning `Dio` as [dio] so the interceptor can resend a request
/// after it refreshes the token (401) or raises trust (403).
///
/// Set [verifyResponses] to `false` if the server does not sign responses.
///
/// **Note:** When [verifyResponses] is `true`, the interceptor temporarily
/// forces [ResponseType.bytes] so it can access the raw response bytes for
/// signature verification, then decodes the bytes back to the original type
/// (JSON or plain text) before returning to the caller.
class CShieldDioInterceptor extends Interceptor {
  /// Whether response signatures are verified. Defaults to `true`.
  final bool verifyResponses;

  /// Selects which requests are signed. `null` (the default) signs **all**
  /// requests. A request the predicate rejects passes through unsigned, and
  /// its response is not verified.
  final bool Function(RequestOptions options)? signWhen;

  /// The `Dio` used to **resend** a request after a recoverable rejection:
  /// a 401 invalid token (the token is refreshed first) or a trust 403 (trust
  /// is raised first, see [requiredLevel]). Each is retried once.
  ///
  /// It must be the **same** `Dio` this interceptor is added to, so the retry
  /// is signed and verified by this interceptor again. With `null`, nothing is
  /// retried and the 401/403 is returned to the app.
  /// ```dart
  /// final dio = Dio();
  /// dio.interceptors.add(CShieldDioInterceptor(dio: dio));
  /// ```
  final Dio? dio;

  /// What to do when attestation is not ready at signing time. Defaults to
  /// [OnNotReady.failFast] (fail-closed).
  final OnNotReady onNotReady;

  /// Maps a sensitive endpoint to the minimum trust level it needs (for
  /// example L4): return the level for that request, or `null` otherwise.
  ///
  /// For a mapped request the interceptor starts [CShieldAttest.ensureTrust]
  /// in the background and sends the request without waiting. If the server
  /// then answers with a trust 403 (`CSHIELD_DEVICE_NOT_ALLOWED` or
  /// `CSHIELD_TRUST_NOT_FRESH`), it raises trust with fresh proof and resends
  /// once; this needs [dio]. It never blocks a request on the client: the
  /// server is what enforces trust. Defaults to `null`:
  /// ```dart
  /// dio.interceptors.add(CShieldDioInterceptor(
  ///   dio: dio,
  ///   requiredLevel: (o) => o.path == '/payment' ? TrustLevel.l4 : null,
  /// ));
  /// ```
  final TrustLevel? Function(RequestOptions options)? requiredLevel;

  const CShieldDioInterceptor({
    this.verifyResponses = true,
    this.signWhen,
    this.dio,
    this.onNotReady = OnNotReady.failFast,
    this.requiredLevel,
  });

  static const _kOriginalResponseType = '_cshield_original_response_type';
  static const _kSkipAip = '_cshield_skip_aip';
  static const _kRetried = '_cshield_retried_invalid_token';
  static const _kRetriedTrust = '_cshield_retried_trust';

  /// Short wait for [OnNotReady.blockRetry], so the UI is not held up for long.
  static const _blockRetryWaitMs = 2000;

  /// `ensureTrust` may have to run Play Integrity (prepare and request), so it
  /// gets a longer timeout.
  static const _ensureTrustTimeoutMs = 15000;

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) async {
    if (signWhen != null && !signWhen!(options)) {
      options.extra[_kSkipAip] = true; // not signed → onResponse skips verification
      handler.next(options);
      return;
    }
    // Endpoint mapped to a trust level: raise trust in the BACKGROUND (fire-and-forget), never
    // awaited inside onRequest. `ensureTrust` may run Play Integrity (up to ~15s), and awaiting it
    // in Dio's onRequest pipeline can hang the request (a deadlock seen in practice). Instead, sign
    // and send right away; if trust is too low the server answers 403
    // (CSHIELD_DEVICE_NOT_ALLOWED / CSHIELD_TRUST_NOT_FRESH) and onError raises trust and resends once.
    unawaited(_ensureTrustBestEffort(requiredLevel?.call(options)));
    try {
      await _sign(options);
      handler.next(options);
    } on CShieldException catch (e, st) {
      if (e.code != CShieldErrorCode.notReady) {
        handler.reject(DioException(requestOptions: options, error: e, stackTrace: st));
        return;
      }
      switch (onNotReady) {
        case OnNotReady.failFast:
          handler.reject(DioException(requestOptions: options, error: e, stackTrace: st));
        case OnNotReady.passThrough:
          options.extra[_kSkipAip] = true; // sent UNSIGNED → onResponse skips verification
          handler.next(options);
        case OnNotReady.blockRetry:
          if (e.retryable == false) {
            handler.reject(DioException(requestOptions: options, error: e, stackTrace: st));
            return;
          }
          await CShieldAttest.awaitReady(timeoutMs: _blockRetryWaitMs);
          try {
            await _sign(options); // retry exactly once; still failing → reject
            handler.next(options);
          } catch (e2, st2) {
            handler.reject(DioException(requestOptions: options, error: e2, stackTrace: st2));
          }
      }
    } catch (e, st) {
      handler.reject(DioException(requestOptions: options, error: e, stackTrace: st));
    }
  }

  /// Raises trust in the BACKGROUND (a warm-up for later requests). Best effort: it is called
  /// fire-and-forget, so it swallows every error (nothing can be thrown back into onRequest).
  ///
  /// A configuration error (`playIntegrityNotConfigured`: `requiredLevel` is set but `initialize`
  /// got no `cloudProjectNumber`) is not lost: a route that demands higher trust gets a 403 from
  /// the server, and onError then calls `ensureTrust(requireFresh: true)` and surfaces that error.
  static Future<void> _ensureTrustBestEffort(TrustLevel? level) async {
    if (level == null || level == TrustLevel.unknown) return;
    try {
      await CShieldAttest.ensureTrust(level, timeoutMs: _ensureTrustTimeoutMs);
    } catch (_) {
      // Runs in the background: never let a trust-raising failure become an unhandled async error.
    }
  }

  /// Signs [options] and attaches the `cs-proof` header. When [verifyResponses] is set, also
  /// forces [ResponseType.bytes] so onResponse can read the raw bytes to verify the signature.
  Future<void> _sign(RequestOptions options) async {
    final aipHeaders = await CShieldAIP.signRequest(
      method: options.method,
      path: options.uri.path,
      query: options.uri.query,
      body: _requestBodyBytes(options),
      contentType: _contentType(options),
    );
    options.headers.addAll(aipHeaders);

    if (verifyResponses) {
      options.extra[_kOriginalResponseType] = options.responseType;
      options.responseType = ResponseType.bytes;
    }
  }

  @override
  void onResponse(Response response, ResponseInterceptorHandler handler) async {
    if (!verifyResponses || response.requestOptions.extra[_kSkipAip] == true) {
      handler.next(response);
      return;
    }

    try {
      final rawBytes = Uint8List.fromList(response.data as List<int>);
      await CShieldAIP.verifyResponse(
          statusCode: response.statusCode ?? 0,
          path: response.requestOptions.uri.path,
          query: response.requestOptions.uri.query,
          headers: _flattenHeaders(response.headers),
          body: rawBytes);

      // Restore original response type so callers receive decoded data.
      final originalType = response.requestOptions.extra[_kOriginalResponseType] as ResponseType? ?? ResponseType.json;
      response.data = _decodeBytes(rawBytes, originalType);
      handler.next(response);
    } catch (e, st) {
      handler.reject(DioException(requestOptions: response.requestOptions, error: e, stackTrace: st));
    }
  }

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) async {
    final opts = err.requestOptions;
    final response = err.response;
    // 401 invalid token → force a token refresh, then resend exactly once (through the same Dio,
    // so the retry is signed and verified by this interceptor again; the _kRetried flag prevents
    // a loop). Needs `dio`; without it the 401 is returned unchanged.
    if (dio != null &&
        response != null &&
        opts.extra[_kSkipAip] != true &&
        opts.extra[_kRetried] != true) {
      final bytes = _responseBytes(response.data);
      if (bytes != null &&
          CShieldAIP.isInvalidAccessToken(response.statusCode ?? 0, bytes) &&
          await CShieldAIP.forceRefresh()) {
        opts.extra[_kRetried] = true;
        _restoreResponseType(opts);
        try {
          final retried = await dio!.fetch(opts);
          return handler.resolve(retried);
        } on DioException catch (e) {
          return handler.next(e);
        } catch (_) {
          return handler.next(err);
        }
      }
    }

    // Trust 403 (below the minimum = CSHIELD_DEVICE_NOT_ALLOWED, or no longer fresh =
    // CSHIELD_TRUST_NOT_FRESH) → raise trust with fresh proof, then resend exactly once. This
    // replaces awaiting ensureTrust in onRequest (which caused hangs): react to the 403 instead
    // of blocking up front.
    if (dio != null &&
        response != null &&
        response.statusCode == 403 &&
        opts.extra[_kSkipAip] != true &&
        opts.extra[_kRetriedTrust] != true) {
      final level = requiredLevel?.call(opts);
      if (level != null && level != TrustLevel.unknown) {
        final bytes = _responseBytes(response.data);
        final body = bytes == null ? '' : utf8.decode(bytes, allowMalformed: true);
        if (body.contains('CSHIELD_DEVICE_NOT_ALLOWED') || body.contains('CSHIELD_TRUST_NOT_FRESH')) {
          EnsureTrustResult? result;
          try {
            result = await CShieldAttest.ensureTrust(level, requireFresh: true, timeoutMs: _ensureTrustTimeoutMs);
          } on CShieldException catch (e, st) {
            // Configuration error (requiredLevel set, but initialize got no cloudProjectNumber)
            // → surface it so the integrator can fix it.
            if (e.code == CShieldErrorCode.playIntegrityNotConfigured) {
              return handler.reject(DioException(requestOptions: opts, response: response, error: e, stackTrace: st));
            }
            // Any other, transient error → let the 403 continue to the app.
          } catch (_) {}
          if (result == EnsureTrustResult.satisfied) {
            opts.extra[_kRetriedTrust] = true;
            _restoreResponseType(opts);
            try {
              final retried = await dio!.fetch(opts);
              return handler.resolve(retried);
            } on DioException catch (e) {
              return handler.next(e);
            } catch (_) {}
          }
        }
      }
    }
    handler.next(err);
  }

  /// Restores `responseType` to its ORIGINAL value before a resend. The retry runs onRequest
  /// again, where _sign forces `bytes` and records `_kOriginalResponseType`; without restoring
  /// first, the "original" type would be recorded as bytes and the caller (for example Retrofit)
  /// would receive bytes instead of JSON. Only restores when _sign changed it (verification on).
  static void _restoreResponseType(RequestOptions opts) {
    final original = opts.extra[_kOriginalResponseType];
    if (original is ResponseType) opts.responseType = original;
  }

  /// Returns the raw bytes of response.data (ResponseType.bytes is set when verifyResponses is
  /// on). If the data is not bytes, encodes it so the error code can still be looked up.
  static Uint8List? _responseBytes(dynamic data) {
    if (data == null) return null;
    if (data is Uint8List) return data;
    if (data is List<int>) return Uint8List.fromList(data);
    if (data is String) return Uint8List.fromList(utf8.encode(data));
    if (data is Map || data is List) {
      return Uint8List.fromList(utf8.encode(jsonEncode(data)));
    }
    return null;
  }

  // ── Helpers ───────────────────────────────────────────────────────────────

  static Uint8List _requestBodyBytes(RequestOptions options) {
    final data = options.data;
    if (data == null) return Uint8List(0);
    if (data is Uint8List) return data;
    if (data is List<int>) return Uint8List.fromList(data);
    if (data is String) return Uint8List.fromList(utf8.encode(data));
    if (data is FormData) return _normalizeFormData(data);
    if (data is Map || data is List) return Uint8List.fromList(utf8.encode(jsonEncode(data)));
    return Uint8List(0);
  }

  /// Normalizes FormData the same way the native SDKs normalize multipart
  /// bodies: text fields only (files skipped), sorted by key, JSON-encoded.
  static Uint8List _normalizeFormData(FormData form) {
    final fields = <String, String>{for (final e in form.fields) e.key: e.value};
    return AIPNormalizer.normalizeFields(fields);
  }

  static String _contentType(RequestOptions options) {
    // When the body is FormData, _requestBodyBytes already normalized it to
    // sorted-JSON bytes, so we must report application/json to the normalizer —
    // not the original multipart/form-data content type — otherwise it tries to
    // parse JSON bytes as multipart and produces the wrong hash.
    if (options.data is FormData) return 'application/json';
    return options.contentType ?? options.headers['content-type']?.toString() ?? 'application/json';
  }

  static Map<String, String> _flattenHeaders(Headers headers) =>
      {for (final e in headers.map.entries) e.key: e.value.first};

  static dynamic _decodeBytes(Uint8List bytes, ResponseType type) {
    if (type == ResponseType.bytes || type == ResponseType.stream) return bytes;
    final str = utf8.decode(bytes, allowMalformed: true);
    if (type == ResponseType.plain) return str;
    try {
      return jsonDecode(str);
    } catch (_) {
      return str;
    }
  }
}
