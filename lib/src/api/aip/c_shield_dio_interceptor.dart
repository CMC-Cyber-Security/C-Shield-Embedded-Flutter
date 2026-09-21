import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';

import '../../internal/aip/aip_normalizer.dart';
import 'c_shield_aip.dart';

/// A Dio [Interceptor] that automatically signs every outgoing request
/// and verifies every incoming response using CShield AIP.
///
/// Add it once when creating your Dio instance:
/// ```dart
/// final dio = Dio(BaseOptions(baseUrl: 'https://api.example.com'));
/// dio.interceptors.add(CShieldDioInterceptor());
/// ```
///
/// Combined with SSL pinning:
/// ```dart
/// import 'package:dio/io.dart';
///
/// dio.httpClientAdapter = IOHttpClientAdapter(
///   createHttpClient: CShieldSSL.createHttpClient,
/// );
/// dio.interceptors.add(CShieldDioInterceptor());
/// ```
///
/// Set [verifyResponses] to `false` if the server does not sign responses.
///
/// **Note:** When [verifyResponses] is `true`, the interceptor temporarily
/// forces [ResponseType.bytes] so it can access the raw response bytes for
/// signature verification, then decodes the bytes back to the original type
/// (JSON or plain text) before returning to the caller.
class CShieldDioInterceptor extends Interceptor {
  final bool verifyResponses;

  const CShieldDioInterceptor({this.verifyResponses = true});

  static const _kOriginalResponseType = '_cshield_original_response_type';

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) async {
    try {
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

      handler.next(options);
    } catch (e, st) {
      handler.reject(DioException(requestOptions: options, error: e, stackTrace: st));
    }
  }

  @override
  void onResponse(Response response, ResponseInterceptorHandler handler) async {
    if (!verifyResponses) {
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
  void onError(DioException err, ErrorInterceptorHandler handler) => handler.next(err);

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

  /// Normalizes FormData to match AIPUtils.normalizeMultipart() on Android/iOS:
  /// text fields only (files skipped), sorted by key, JSON-encoded.
  static Uint8List _normalizeFormData(FormData form) {
    final fields = <String, String>{for (final e in form.fields) e.key: e.value};
    return AIPNormalizer.normalizeFields(fields);
  }

  static String _contentType(RequestOptions options) {
    // When the body is FormData, _requestBodyBytes already normalized it to
    // sorted-JSON bytes, so we must report application/json to native — not the
    // original multipart/form-data content type — otherwise AIPCore tries to
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
