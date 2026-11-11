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

  /// Chọn request nào được ký (mặc định `null` = ký TẤT CẢ). Request không khớp đi qua
  /// KHÔNG ký + KHÔNG verify response (ký chọn lọc vài API).
  final bool Function(RequestOptions options)? signWhen;

  /// Dio để **gửi lại** request khi server 401 invalid-token (force refresh token rồi thử lại 1
  /// lần). Phải là CHÍNH Dio mà interceptor này gắn vào (để lượt retry ký lại + verify qua
  /// interceptor). `null` → KHÔNG tự retry (vẫn trả 401 cho app). Cách dùng:
  /// ```dart
  /// final dio = Dio();
  /// dio.interceptors.add(CShieldDioInterceptor(dio: dio));
  /// ```
  final Dio? dio;

  /// Chính sách khi attestation chưa sẵn sàng. Mặc định [OnNotReady.failFast] (fail-closed).
  final OnNotReady onNotReady;

  /// Gắn mức trust tối thiểu cho endpoint nhạy (vd ≥L4): trả mức cần cho request đó, else `null`.
  /// Trước khi ký, interceptor CHỦ ĐỘNG gọi [CShieldAttest.ensureTrust] để nâng (Play Integrity)
  /// nếu thiếu — best-effort, KHÔNG chặn ở client (server mới là nơi chốt trust). Mặc định `null`:
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

  /// Chờ ngắn khi [OnNotReady.blockRetry] — không treo UI lâu.
  static const _blockRetryWaitMs = 2000;

  /// `ensureTrust` có thể phải chạy Play Integrity (prepare + request) → cho thời gian rộng hơn.
  static const _ensureTrustTimeoutMs = 15000;

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) async {
    if (signWhen != null && !signWhen!(options)) {
      options.extra[_kSkipAip] = true; // không ký → onResponse bỏ verify
      handler.next(options);
      return;
    }
    // Endpoint nhạy được gắn mức: nâng trust chạy NỀN (fire-and-forget), KHÔNG await trong onRequest.
    // `ensureTrust` có thể chạy Play Integrity (tới ~15s); await nó ngay trong pipeline onRequest của
    // dio có thể TREO request (deadlock quan sát thực tế). Thay vào đó ký + gửi ngay; thiếu trust thì
    // server trả 403 (CSHIELD_DEVICE_NOT_ALLOWED / CSHIELD_TRUST_NOT_FRESH) → onError nâng + gửi lại 1 lần.
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
          options.extra[_kSkipAip] = true; // gửi KHÔNG ký → onResponse bỏ verify
          handler.next(options);
        case OnNotReady.blockRetry:
          if (e.retryable == false) {
            handler.reject(DioException(requestOptions: options, error: e, stackTrace: st));
            return;
          }
          await CShieldAttest.awaitReady(timeoutMs: _blockRetryWaitMs);
          try {
            await _sign(options); // thử lại ĐÚNG 1 lần; vẫn fail → reject
            handler.next(options);
          } catch (e2, st2) {
            handler.reject(DioException(requestOptions: options, error: e2, stackTrace: st2));
          }
      }
    } catch (e, st) {
      handler.reject(DioException(requestOptions: options, error: e, stackTrace: st));
    }
  }

  /// Nâng trust NỀN (warm-up cho các request sau) — BEST-EFFORT, gọi fire-and-forget nên NUỐT mọi
  /// lỗi (không thể ném ngược vào onRequest). Sai cấu hình (`playIntegrityNotConfigured`: đặt
  /// `requiredLevel` nhưng `initialize` thiếu `cloudProjectNumber`) KHÔNG bị nuốt oan: route đòi
  /// trust cao sẽ bị server 403 → onError gọi lại `ensureTrust(requireFresh)` và surface lỗi đó.
  static Future<void> _ensureTrustBestEffort(TrustLevel? level) async {
    if (level == null || level == TrustLevel.unknown) return;
    try {
      await CShieldAttest.ensureTrust(level, timeoutMs: _ensureTrustTimeoutMs);
    } catch (_) {
      // Chạy nền: không để lỗi nâng trust nổi thành unhandled async error.
    }
  }

  /// Ký [options] + gắn header `cs-proof`, và (khi [verifyResponses]) ép [ResponseType.bytes] để
  /// onResponse đọc được bytes thô mà verify chữ ký.
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
    // 401 invalid-token → force refresh token rồi gửi lại ĐÚNG 1 lần (qua chính Dio để lượt retry
    // ký lại + verify qua interceptor; cờ _kRetried chặn lặp). Cần `dio`; không có → trả 401 như cũ.
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

    // 403 trust (dưới ngưỡng = CSHIELD_DEVICE_NOT_ALLOWED, hoặc hết tươi = CSHIELD_TRUST_NOT_FRESH)
    // → nâng trust bằng Play Integrity rồi gửi lại ĐÚNG 1 lần. Đây là nơi THAY cho việc await
    // ensureTrust trong onRequest (vốn gây treo): phản ứng theo 403 thay vì chặn trước.
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
            // Sai cấu hình (requiredLevel nhưng initialize thiếu cloudProjectNumber) → surface để sửa.
            if (e.code == CShieldErrorCode.playIntegrityNotConfigured) {
              return handler.reject(DioException(requestOptions: opts, response: response, error: e, stackTrace: st));
            }
            // lỗi tạm thời khác → để 403 đi tiếp tới app.
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

  /// Trả `responseType` về kiểu GỐC trước khi gửi lại: lượt retry chạy lại onRequest → _sign sẽ tự
  /// ép `bytes` và ghi lại `_kOriginalResponseType`. Không khôi phục thì "kiểu gốc" bị ghi nhầm là
  /// bytes → caller (retrofit) nhận bytes thay vì JSON. Chỉ khôi phục khi _sign từng đổi (verify bật).
  static void _restoreResponseType(RequestOptions opts) {
    final original = opts.extra[_kOriginalResponseType];
    if (original is ResponseType) opts.responseType = original;
  }

  /// Lấy bytes thô từ response.data (đã set ResponseType.bytes khi verifyResponses). Không phải
  /// bytes → thử encode để dò mã lỗi.
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
