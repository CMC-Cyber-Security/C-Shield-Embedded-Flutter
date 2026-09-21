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
/// // cs-timestamp / cs-signature are attached automatically.
/// // Response signature is verified automatically before returning.
/// ```
///
/// Set [verifyResponses] to `false` if the server does not sign responses.
class CShieldInterceptor extends http.BaseClient {
  final http.Client _inner;
  final bool verifyResponses;

  CShieldInterceptor({http.Client? inner, this.verifyResponses = true}) : _inner = inner ?? http.Client();

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final path = request.url.path;
    final (body, contentType) = _bodyAndContentType(request);

    // 1. Sign request — attach cs-timestamp + cs-signature headers.
    final aipHeaders = await CShieldAIP.signRequest(
      method: request.method,
      path: path,
      query: request.url.query,
      body: body,
      contentType: contentType,
    );

    request.headers.addAll(aipHeaders);

    // 2. Forward the signed request.
    final streamed = await _inner.send(request);

    if (!verifyResponses) return streamed;

    // 3. Buffer response body so we can verify the signature.
    final responseBytes = await streamed.stream.toBytes();
    await CShieldAIP.verifyResponse(
        statusCode: streamed.statusCode,
        path: path,
        query: request.url.query,
        headers: streamed.headers,
        body: responseBytes);

    // 4. Reconstruct StreamedResponse with the buffered body.
    return http.StreamedResponse(
      Stream.value(responseBytes),
      streamed.statusCode,
      headers: streamed.headers,
      reasonPhrase: streamed.reasonPhrase,
      contentLength: responseBytes.length,
      isRedirect: streamed.isRedirect,
      persistentConnection: streamed.persistentConnection,
      request: streamed.request,
    );
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
