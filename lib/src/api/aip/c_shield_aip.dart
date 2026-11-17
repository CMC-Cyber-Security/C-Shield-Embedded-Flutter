import 'dart:convert';
import 'dart:typed_data';

import 'package:c_shield_embedded/src/api/exceptions/c_shield_exception.dart';
import 'package:c_shield_embedded/src/internal/aip/aip_canonical_query.dart';
import 'package:c_shield_embedded/src/internal/aip/aip_normalizer.dart';
import 'package:c_shield_embedded/src/internal/platform/c_shield_embedded_platform_interface.dart';

/// Low-level AIP (API Integrity Protection) API.
///
/// ## How to use it
///
/// **Automatic (recommended):** `CShieldInterceptor` (`http` package) or
/// `CShieldDioInterceptor` (Dio) sign requests and verify responses
/// transparently.
///
/// **Manual:** [signRequest] signs one request and returns the `cs-proof`
/// header for you to attach; [verifyResponse] verifies a response.
///
/// ## Request signing: the `cs-proof` header
/// [signRequest] returns `{'cs-proof': <base64>}`, an attested envelope holding
/// the access token, a request id, a timestamp, the request hash, and an
/// ECDSA signature made with the device's hardware key. Attach the map to the
/// request headers as is and send the request **immediately**: the request id
/// is single-use and the timestamp is only valid within ±30 seconds, so a
/// proof must never be cached or reused.
///
/// ## Response verification
/// The server signs each response over
/// `{statusCode}.{path}[?{canonicalQuery}].{unixTimestamp}.{bodyHash}` and
/// sends the `cs-timestamp` and `cs-signature` headers. [verifyResponse]
/// checks the ±30 second window and then verifies the signature. `path` is
/// the raw URL path and `bodyHash` is the lowercase hex SHA-256 of the raw
/// response bytes.
class CShieldAIP {
  CShieldAIP._();

  /// Freshness window (seconds) for response timestamps — guards against
  /// replay and clock skew. Must match the native interceptors
  /// (`RESPONSE_FRESHNESS_SECONDS` on Android/iOS) and the server's
  /// `requestTimeoutSeconds`.
  static const int _responseFreshnessSeconds = 30;

  static int _nowSeconds() => DateTime.now().millisecondsSinceEpoch ~/ 1000;

  /// Verifies [signature] against [payload] on the native side.
  ///
  /// Throws [CShieldException] with [CShieldErrorCode.aipInvalidSignature] if
  /// the signature does not match. This is the raw cryptographic check; the
  /// timestamp window is checked by [verifyResponse].
  static Future<void> verify({required String payload, required String signature}) =>
      CShieldEmbeddedPlatform.instance.aipVerify(payload: payload, signature: signature);

  /// Normalizes [body] bytes to their canonical signing form.
  ///
  /// Returns `{'normalizedString': String, 'sizeInBytes': int, 'hash': String}`.
  /// - For `multipart/form-data`: text fields only, sorted, JSON-encoded.
  /// - For other types: raw bytes as UTF-8 string.
  ///
  /// Computed entirely in Dart (see [AIPNormalizer]) — byte-identical to the
  /// native implementation — so it does not cross the method channel.
  ///
  /// `hash` is the body hash that [signRequest] puts into the signed request.
  static Future<Map<String, dynamic>> normalizeBody(
          {required Uint8List body, String contentType = 'application/json'}) async =>
      AIPNormalizer.normalizeBodyForSigning(body: body, contentType: contentType).toMap();

  // ── Request signing / response verification ──────────────────────────────

  /// Signs an outgoing request and returns the AIP header map (`{'cs-proof': ...}`).
  ///
  /// [path] must be the URL path only. [query] is the raw query string (the
  /// part after `?`), or `''` when there is none; it is canonicalized before
  /// signing. [body] is the request body as sent. For `multipart/form-data`,
  /// pass the raw multipart bytes together with the multipart [contentType]
  /// (including its boundary): only the text fields are hashed.
  ///
  /// The request components cross to native, which builds the canonical
  /// request, signs it with the device hardware key and returns the `cs-proof`
  /// header (ECDSA signature + access token). The server verifies `cs-proof`
  /// against the device's registered public key.
  ///
  /// Throws [CShieldException] with [CShieldErrorCode.notReady] if attestation
  /// is not ready, or [CShieldErrorCode.aipSigningFailed] if signing fails
  /// (for example a malformed query string).
  static Future<Map<String, String>> signRequest({
    required String method,
    required String path,
    required String query,
    required Uint8List body,
    String contentType = 'application/json',
  }) async {
    final normalized = AIPNormalizer.normalizeBodyForSigning(body: body, contentType: contentType);
    final signature = await CShieldEmbeddedPlatform.instance.aipSignRequest(
      method: method,
      path: path,
      canonicalQuery: AIPCanonicalQuery.canonicalQuery(query),
      timestampSec: _nowSeconds(),
      bodyHashHex: normalized.hash,
    );

    return signature.cast();
  }

  /// Verifies the AIP signature on an incoming response.
  ///
  /// [headers] should contain `cs-timestamp` and `cs-signature` (matched
  /// case-insensitively). [body] must be the raw response bytes, not decoded.
  /// Pass the same [path] and [query] the request was signed with.
  ///
  /// The timestamp window check and the payload
  /// (`{statusCode}.{path}[?{canonicalQuery}].{timestamp}.{bodyHash}`) are
  /// computed in Dart; only the cryptographic [verify] crosses to native.
  /// Throws [CShieldException] on failure.
  ///
  /// When the signature headers are **missing**, the policy depends on the
  /// status:
  ///  - 2xx: the headers are mandatory, since they protect the integrity of
  ///    the data. Missing headers throw [CShieldErrorCode.aipMissingHeader].
  ///  - non-2xx: the server may deliberately not sign (for example a 500 or
  ///    502), or the error may come from infrastructure in front of it.
  ///    Verification is skipped and the call returns, so the caller sees the
  ///    real status and body instead of an exception.
  ///
  /// When the headers are present, the response is always verified, whatever
  /// its status; a bad signature throws.
  static Future<void> verifyResponse(
      {required int statusCode,
      required String path,
      required String query,
      required Map<String, String> headers,
      required Uint8List body}) async {
    final lower = {for (final e in headers.entries) e.key.toLowerCase(): e.value};
    final timestampStr = lower['cs-timestamp'];
    final signature = lower['cs-signature'];
    final isSuccess = statusCode >= 200 && statusCode < 300;

    if (timestampStr == null || signature == null) {
      if (isSuccess) {
        throw const CShieldException(
            CShieldErrorCode.aipMissingHeader, '2xx response is missing its signature (cs-timestamp/cs-signature)');
      }
      return; // unsigned non-2xx error → accepted, not verified
    }

    final timestamp = int.tryParse(timestampStr);
    if (timestamp == null) {
      throw const CShieldException(CShieldErrorCode.aipTimestampExpired, 'Invalid cs-timestamp format');
    }
    if ((_nowSeconds() - timestamp).abs() > _responseFreshnessSeconds) {
      throw const CShieldException(CShieldErrorCode.aipTimestampExpired, 'Timeout response handle');
    }

    String canonicalQuery = AIPCanonicalQuery.canonicalQuery(query);
    if (canonicalQuery.isNotEmpty) {
      canonicalQuery = '?$canonicalQuery';
    }

    // Hash the raw response bytes as-is, exactly like native validateResponse.
    final bodyHash = AIPNormalizer.sha256Hex(body);
    final payload = '$statusCode.$path$canonicalQuery.$timestamp.$bodyHash';
    await verify(payload: payload, signature: signature);
  }

  /// Forces an access-token refresh after the server rejected the current
  /// token (401 invalid token). Returns `true` if a new token is ready
  /// afterwards. The interceptors use it to sign again and resend once.
  static Future<bool> forceRefresh({int timeoutMs = 5000}) =>
      CShieldEmbeddedPlatform.instance.aipForceRefresh(timeoutMs: timeoutMs);

  /// Whether a response is a 401 caused by an expired or invalid access token
  /// on the server side. Looks for the `CSHIELD_INVALID_ACCESS_TOKEN` code in
  /// the error body.
  ///
  /// Only this code is worth a forced refresh and a retry. Other 401s
  /// (signature mismatch, stale or replayed request) and a 403 for an
  /// insufficient trust level are not.
  static bool isInvalidAccessToken(int statusCode, Uint8List body) {
    if (statusCode != 401) return false;
    final text = _utf8OrEmpty(body);
    return text.contains('CSHIELD_INVALID_ACCESS_TOKEN');
  }

  static String _utf8OrEmpty(Uint8List bytes) {
    try {
      return utf8.decode(bytes, allowMalformed: true);
    } catch (_) {
      return '';
    }
  }
}
