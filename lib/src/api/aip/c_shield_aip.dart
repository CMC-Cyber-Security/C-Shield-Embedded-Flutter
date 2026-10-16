import 'dart:typed_data';

import 'package:c_shield_embedded/src/api/exceptions/c_shield_exception.dart';
import 'package:c_shield_embedded/src/internal/aip/aip_canonical_query.dart';
import 'package:c_shield_embedded/src/internal/aip/aip_normalizer.dart';
import 'package:c_shield_embedded/src/internal/platform/c_shield_embedded_platform_interface.dart';

/// Low-level AIP (API Integrity Protection) API.
///
/// ## Cách dùng
///
/// **Tự động (khuyến nghị):** [CShieldInterceptor] (`http`) hoặc [CShieldDioInterceptor]
/// (Dio) — ký request + verify response trong suốt.
///
/// **Thủ công:** [signRequest] ký một request → trả header `cs-proof` để tự gắn (ký chọn lọc
/// vài API); [verifyResponse] verify response.
///
/// ## Ký request — header `cs-proof`
/// [signRequest] trả `{'cs-proof': <base64>}` (envelope attested: accessToken + requestId +
/// timestamp + requestHash + chữ ký ECDSA bằng hardware key). Gắn NGUYÊN map vào header rồi
/// gửi NGAY — `requestId` one-time + `timestamp` cửa sổ ±30s → KHÔNG cache/tái dùng.
///
/// ## Verify response
/// Server ký response theo `{statusCode}.{path}.{unixTimestamp}.{bodyHash}` + header
/// `cs-timestamp`/`cs-signature`; [verifyResponse] kiểm cửa sổ ±30s rồi verify.
/// `path` = URL path (không query); `bodyHash` = SHA-256 hex của body đã chuẩn hoá
/// (multipart: bỏ file part, sort key, JSON-encode; còn lại: bytes thô).
class CShieldAIP {
  CShieldAIP._();

  /// Freshness window (seconds) for response timestamps — guards against
  /// replay and clock skew. Must match the native interceptors
  /// (`RESPONSE_FRESHNESS_SECONDS` on Android/iOS) and the server's
  /// `requestTimeoutSeconds`.
  static const int _responseFreshnessSeconds = 30;

  static int _nowSeconds() => DateTime.now().millisecondsSinceEpoch ~/ 1000;

  /// Verifies [signature] against [payload].
  ///
  /// Throws [CShieldException] with [CShieldErrorCode.aipInvalidSignature] or
  /// [CShieldErrorCode.aipTimestampExpired] on failure.
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
  /// Pass the `hash` value when building a payload for [sign].
  static Future<Map<String, dynamic>> normalizeBody(
          {required Uint8List body, String contentType = 'application/json'}) async =>
      AIPNormalizer.normalizeBodyForSigning(body: body, contentType: contentType).toMap();

  // ── Mode 2b: Interceptor helpers — SDK constructs payload automatically ───

  /// Signs an outgoing request and returns the AIP header map (`{'cs-proof': ...}`).
  ///
  /// [path] must be the URL path only (no query string).
  /// [body] should be normalized multipart bytes for file-upload requests
  /// (see [normalizeBody]) or raw JSON/text bytes for regular requests.
  ///
  /// The request components cross to native, which builds the canonical request,
  /// signs it with the device hardware key and returns the `cs-proof` header
  /// (ECDSA signature + access token). The server verifies cs-proof against the
  /// device's registered public key.
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
  /// [headers] must contain `cs-timestamp` and `cs-signature`.
  /// [body] must be the raw response bytes (not decoded).
  ///
  /// The timestamp window check and payload (`{statusCode}.{path}.{timestamp}.
  /// {bodyHash}`) are computed in Dart; only the cryptographic [verify] crosses
  /// to native. Throws [CShieldException] on failure.
  static Future<void> verifyResponse(
      {required int statusCode,
      required String path,
      required String query,
      required Map<String, String> headers,
      required Uint8List body}) async {
    final lower = {for (final e in headers.entries) e.key.toLowerCase(): e.value};

    final timestampStr = lower['cs-timestamp'];
    if (timestampStr == null) {
      throw const CShieldException(CShieldErrorCode.aipMissingHeader, "Not found cs-timestamp in response's header");
    }
    final timestamp = int.tryParse(timestampStr);
    if (timestamp == null) {
      throw const CShieldException(CShieldErrorCode.aipTimestampExpired, 'Invalid cs-timestamp format');
    }
    if ((_nowSeconds() - timestamp).abs() > _responseFreshnessSeconds) {
      throw const CShieldException(CShieldErrorCode.aipTimestampExpired, 'Timeout response handle');
    }

    final signature = lower['cs-signature'];
    if (signature == null) {
      throw const CShieldException(CShieldErrorCode.aipMissingHeader, "Not found cs-signature in response's header");
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
}
