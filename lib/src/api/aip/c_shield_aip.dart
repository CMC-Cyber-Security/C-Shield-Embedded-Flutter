import 'dart:convert';
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
  /// Chính sách status-aware khi response THIẾU chữ ký:
  ///  - 2xx (success): BẮT BUỘC có `cs-timestamp` + `cs-signature` (bảo vệ toàn vẹn data) → thiếu ⇒ ném.
  ///  - non-2xx (lỗi): server có thể cố tình KHÔNG ký (signable=false: 502/500) hoặc lỗi hạ tầng/không
  ///    phải cshield → BỎ QUA verify, trả về (interceptor giữ status/thân thật, không che bằng exception).
  ///  Có đủ header thì luôn verify (cả 2xx lẫn non-2xx); sai chữ ký ⇒ ném.
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
            CShieldErrorCode.aipMissingHeader, 'Response 2xx thiếu chữ ký (cs-timestamp/cs-signature)');
      }
      return; // lỗi non-2xx không ký → chấp nhận, không verify
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

  /// Force refresh token khi server từ chối token hiện tại (401 invalid-token). Trả `true` nếu sau
  /// đó đã sẵn sàng (có token mới) — interceptor dùng để ký lại + gửi lại 1 lần.
  static Future<bool> forceRefresh({int timeoutMs = 5000}) =>
      CShieldEmbeddedPlatform.instance.aipForceRefresh(timeoutMs: timeoutMs);

  /// Response có phải 401 do access token hết hạn/không hợp lệ phía server? Dò mã
  /// `CSHIELD_INVALID_ACCESS_TOKEN` trong body lỗi (server ký nên đã qua verify). CHỈ mã này mới đáng
  /// force-refresh + retry; 401 khác (signature_mismatch/stale/replay) / 403 device_not_allowed thì không.
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
