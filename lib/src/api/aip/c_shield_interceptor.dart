import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../../internal/aip/aip_normalizer.dart';
import 'c_shield_aip.dart';

/// An [http.BaseClient] that automatically signs every outgoing request
/// and verifies every incoming response using CShield AIP.
///
/// Plug it in like any other [http.Client]:
/// ```dart
/// final client = CShieldInterceptor();
///
/// // Or wrap an existing client (e.g. one with SSL pinning):
/// final client = CShieldInterceptor(inner: myPinnedClient);
///
/// final response = await client.post(
///   Uri.parse('https://api.example.com/users'),
///   headers: {'Content-Type': 'application/json'},
///   body: jsonEncode({'name': 'Alice'}),
/// );
/// // The cs-proof header is attached automatically.
/// // Response signature is verified automatically before returning.
/// ```
///
/// Set [verifyResponses] to `false` if the server does not sign responses.
class CShieldInterceptor extends http.BaseClient {
  final http.Client _inner;
  final bool verifyResponses;

  /// Chọn request nào được ký (mặc định `null` = ký TẤT CẢ). Request không khớp đi qua
  /// KHÔNG ký + KHÔNG verify response (ký chọn lọc vài API).
  final bool Function(http.BaseRequest request)? signWhen;

  CShieldInterceptor({http.Client? inner, this.verifyResponses = true, this.signWhen})
      : _inner = inner ?? http.Client();

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (signWhen != null && !signWhen!(request)) {
      return _inner.send(request); // không thuộc diện ký → forward nguyên bản
    }

    final (body, contentType) = _bodyAndContentType(request);
    final attempt = await _signProceedVerify(request, body, contentType, isRetry: false);

    // Server từ chối access token (401 invalid-token) → force refresh + thử lại ĐÚNG 1 lần với
    // token mới. Chỉ clone lại được http.Request (JSON); loại khác (multipart) → trả nguyên 401.
    if (attempt.retryableInvalidToken) {
      final clone = _cloneRequest(request);
      if (clone != null && await CShieldAIP.forceRefresh()) {
        return (await _signProceedVerify(clone, body, contentType, isRetry: true)).response;
      }
    }
    return attempt.response;
  }

  /// Ký → gửi → (nếu verify) buffer body + verifyResponse(status-aware) → dựng lại StreamedResponse.
  /// Trả kèm cờ `retryableInvalidToken` (401 invalid-token, và chưa phải lượt retry).
  Future<_Attempt> _signProceedVerify(
    http.BaseRequest request,
    Uint8List body,
    String contentType, {
    required bool isRetry,
  }) async {
    final path = request.url.path;
    final aipHeaders = await CShieldAIP.signRequest(
      method: request.method,
      path: path,
      query: request.url.query,
      body: body,
      contentType: contentType,
    );
    request.headers.addAll(aipHeaders);

    final streamed = await _inner.send(request);
    if (!verifyResponses) return _Attempt(streamed, false);

    final responseBytes = await streamed.stream.toBytes();
    await CShieldAIP.verifyResponse(
        statusCode: streamed.statusCode,
        path: path,
        query: request.url.query,
        headers: streamed.headers,
        body: responseBytes);

    final rebuilt = http.StreamedResponse(
      Stream.value(responseBytes),
      streamed.statusCode,
      headers: streamed.headers,
      reasonPhrase: streamed.reasonPhrase,
      contentLength: responseBytes.length,
      isRedirect: streamed.isRedirect,
      persistentConnection: streamed.persistentConnection,
      request: streamed.request,
    );
    final retryable = !isRetry && CShieldAIP.isInvalidAccessToken(streamed.statusCode, responseBytes);
    return _Attempt(rebuilt, retryable);
  }

  /// Clone request để gửi lại (chỉ http.Request — bodyBytes giữ lại sau send; cs-proof cũ sẽ bị
  /// ký-lại ghi đè). Loại khác (multipart…) → null = không retry.
  http.BaseRequest? _cloneRequest(http.BaseRequest original) {
    if (original is http.Request) {
      final c = http.Request(original.method, original.url)
        ..followRedirects = original.followRedirects
        ..maxRedirects = original.maxRedirects
        ..persistentConnection = original.persistentConnection
        ..bodyBytes = original.bodyBytes;
      c.headers.addAll(original.headers);
      return c;
    }
    return null;
  }

  @override
  void close() => _inner.close();

  // ── Helpers ───────────────────────────────────────────────────────────────

  /// Returns the bytes to sign and the content type to report to the normalizer.
  static (Uint8List, String) _bodyAndContentType(http.BaseRequest request) {
    if (request is http.MultipartRequest) {
      // Mirror native: only text fields are signed (files skipped), sorted and
      // JSON-encoded. Report application/json so the payload hash matches the
      // multipart text fields the server extracts. The original multipart
      // request (with files) is still sent on the wire unchanged.
      return (AIPNormalizer.normalizeFields(request.fields), 'application/json');
    }
    if (request is http.Request) {
      return (request.bodyBytes, _contentTypeOf(request));
    }
    return (Uint8List(0), _contentTypeOf(request));
  }

  static String _contentTypeOf(http.BaseRequest request) {
    // http package does not normalise header names — check both cases.
    return request.headers['content-type'] ?? request.headers['Content-Type'] ?? 'application/json';
  }
}

/// Kết quả một lượt ký+gửi+verify: response đã dựng lại + có phải 401 invalid-token (đáng retry) không.
class _Attempt {
  final http.StreamedResponse response;
  final bool retryableInvalidToken;
  _Attempt(this.response, this.retryableInvalidToken);
}
