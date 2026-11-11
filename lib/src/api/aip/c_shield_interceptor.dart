import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../../internal/aip/aip_normalizer.dart';
import '../attest/c_shield_attest.dart';
import '../attest/ensure_trust_result.dart';
import '../attest/trust_level.dart';
import '../exceptions/c_shield_exception.dart';
import 'c_shield_aip.dart';
import 'on_not_ready.dart';

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
///
/// Endpoint nhạy cần trust cao thì gắn [requiredLevel] — interceptor tự `ensureTrust` trước khi ký:
/// ```dart
/// final client = CShieldInterceptor(
///   requiredLevel: (r) => r.url.path == '/payment' ? TrustLevel.l4 : null,
/// );
/// ```
class CShieldInterceptor extends http.BaseClient {
  final http.Client _inner;
  final bool verifyResponses;

  /// Chọn request nào được ký (mặc định `null` = ký TẤT CẢ). Request không khớp đi qua
  /// KHÔNG ký + KHÔNG verify response (ký chọn lọc vài API).
  final bool Function(http.BaseRequest request)? signWhen;

  /// Chính sách khi attestation chưa sẵn sàng. Mặc định [OnNotReady.failFast] (fail-closed).
  final OnNotReady onNotReady;

  /// Gắn mức trust tối thiểu cho endpoint nhạy (vd ≥L4): trả mức cần cho request đó, else `null`.
  /// Trước khi ký, interceptor CHỦ ĐỘNG gọi [CShieldAttest.ensureTrust] để nâng (Play Integrity)
  /// nếu thiếu — best-effort, KHÔNG chặn ở client (server mới là nơi chốt trust). Mặc định `null`.
  final TrustLevel? Function(http.BaseRequest request)? requiredLevel;

  CShieldInterceptor({
    http.Client? inner,
    this.verifyResponses = true,
    this.signWhen,
    this.onNotReady = OnNotReady.failFast,
    this.requiredLevel,
  }) : _inner = inner ?? http.Client();

  /// Chờ ngắn khi [OnNotReady.blockRetry] — không treo UI lâu.
  static const _blockRetryWaitMs = 2000;

  /// `ensureTrust` có thể phải chạy Play Integrity (prepare + request) → cho thời gian rộng hơn.
  static const _ensureTrustTimeoutMs = 15000;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (signWhen != null && !signWhen!(request)) {
      return _inner.send(request); // không thuộc diện ký → forward nguyên bản
    }

    // Endpoint nhạy được gắn mức: nâng trust chạy NỀN (fire-and-forget), KHÔNG await trước khi ký.
    // `ensureTrust` có thể chạy Play Integrity (tới ~15s); không chặn hot-path gửi request. Thiếu
    // trust thì server trả 403 → ta nâng + gửi lại 1 lần (dưới đây).
    unawaited(_ensureTrustBestEffort(requiredLevel?.call(request)));

    final (body, contentType) = _bodyAndContentType(request);
    final _Attempt attempt;
    try {
      attempt = await _signProceedVerify(request, body, contentType, isRetry: false);
    } on CShieldException catch (e) {
      if (e.code != CShieldErrorCode.notReady) rethrow;
      switch (onNotReady) {
        case OnNotReady.failFast:
          rethrow;
        case OnNotReady.passThrough:
          return _inner.send(request); // KHÔNG ký
        case OnNotReady.blockRetry:
          if (e.retryable == false) rethrow;
          await CShieldAttest.awaitReady(timeoutMs: _blockRetryWaitMs);
          // Thử lại ĐÚNG 1 lần (request chưa hề được gửi — sign ném trước khi đi dây).
          return (await _signProceedVerify(request, body, contentType, isRetry: true)).response;
      }
    }

    // Server từ chối access token (401 invalid-token) → force refresh + thử lại ĐÚNG 1 lần với
    // token mới. Chỉ clone lại được http.Request (JSON); loại khác (multipart) → trả nguyên 401.
    if (attempt.retryableInvalidToken) {
      final clone = _cloneRequest(request);
      if (clone != null && await CShieldAIP.forceRefresh()) {
        return (await _signProceedVerify(clone, body, contentType, isRetry: true)).response;
      }
    }

    // Server từ chối vì trust (403 CSHIELD_DEVICE_NOT_ALLOWED / CSHIELD_TRUST_NOT_FRESH) → nâng
    // trust (Play Integrity) rồi gửi lại ĐÚNG 1 lần. Đây là nơi THAY cho việc await ensureTrust
    // trước khi ký — react theo 403 thay vì chặn trước.
    if (attempt.retryableTrust) {
      final level = requiredLevel?.call(request);
      final clone = _cloneRequest(request);
      if (level != null && level != TrustLevel.unknown && clone != null) {
        EnsureTrustResult? result;
        try {
          result = await CShieldAttest.ensureTrust(level, requireFresh: true, timeoutMs: _ensureTrustTimeoutMs);
        } on CShieldException catch (e) {
          // Sai cấu hình (requiredLevel nhưng initialize thiếu cloudProjectNumber) → surface để sửa.
          if (e.code == CShieldErrorCode.playIntegrityNotConfigured) rethrow;
          // lỗi tạm thời khác → để 403 đi tiếp tới app.
        }
        if (result == EnsureTrustResult.satisfied) {
          return (await _signProceedVerify(clone, body, contentType, isRetry: true)).response;
        }
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
    if (!verifyResponses) return _Attempt(streamed, false, false);

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
    final retryableTrust = !isRetry && streamed.statusCode == 403 && _isTrustRejected(responseBytes);
    return _Attempt(rebuilt, retryable, retryableTrust);
  }

  /// 403 có phải do trust (dưới ngưỡng / hết tươi) không — để quyết định nâng trust + gửi lại.
  static bool _isTrustRejected(Uint8List bytes) {
    final body = utf8.decode(bytes, allowMalformed: true);
    return body.contains('CSHIELD_DEVICE_NOT_ALLOWED') || body.contains('CSHIELD_TRUST_NOT_FRESH');
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

  /// Nâng trust trước khi ký — BEST-EFFORT cho lỗi tạm thời: KHÔNG chặn request vì server mới chốt
  /// trust.
  ///
  /// NGOẠI LỆ: `playIntegrityNotConfigured` là lỗi SAI CẤU HÌNH (đặt `requiredLevel` nhưng
  /// `initialize` không truyền `cloudProjectNumber` ⇒ PI tắt) → **ném lại** để bên tích hợp sửa.
  static Future<void> _ensureTrustBestEffort(TrustLevel? level) async {
    if (level == null || level == TrustLevel.unknown) return;
    try {
      await CShieldAttest.ensureTrust(level, timeoutMs: _ensureTrustTimeoutMs);
    } catch (_) {
      // Chạy nền (fire-and-forget): nuốt mọi lỗi. Sai cấu hình (playIntegrityNotConfigured) sẽ được
      // surface ở nhánh retry 403 (ensureTrust(requireFresh) ném → rethrow cho app).
    }
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

/// Kết quả một lượt ký+gửi+verify: response đã dựng lại + cờ đáng retry (401 invalid-token /
/// 403 trust).
class _Attempt {
  final http.StreamedResponse response;
  final bool retryableInvalidToken;
  final bool retryableTrust;
  _Attempt(this.response, this.retryableInvalidToken, this.retryableTrust);
}
