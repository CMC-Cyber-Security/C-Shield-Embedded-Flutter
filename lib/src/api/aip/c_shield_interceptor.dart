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
/// For a sensitive endpoint that needs a high trust level, set
/// [requiredLevel]: the interceptor raises trust for it and retries once when
/// the server rejects the request for insufficient trust.
/// ```dart
/// final client = CShieldInterceptor(
///   requiredLevel: (r) => r.url.path == '/payment' ? TrustLevel.l4 : null,
/// );
/// ```
class CShieldInterceptor extends http.BaseClient {
  final http.Client _inner;

  /// Whether response signatures are verified. Defaults to `true`.
  final bool verifyResponses;

  /// Selects which requests are signed. `null` (the default) signs **all**
  /// requests. A request the predicate rejects passes through unsigned, and
  /// its response is not verified.
  final bool Function(http.BaseRequest request)? signWhen;

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
  /// once (only an [http.Request] can be resent). It never blocks a request on
  /// the client: the server is what enforces trust. Defaults to `null`.
  final TrustLevel? Function(http.BaseRequest request)? requiredLevel;

  /// Creates the client. [inner] is the client that actually sends requests;
  /// pass one with SSL pinning to combine both. Defaults to `http.Client()`.
  CShieldInterceptor({
    http.Client? inner,
    this.verifyResponses = true,
    this.signWhen,
    this.onNotReady = OnNotReady.failFast,
    this.requiredLevel,
  }) : _inner = inner ?? http.Client();

  /// Short wait for [OnNotReady.blockRetry], so the UI is not held up for long.
  static const _blockRetryWaitMs = 2000;

  /// `ensureTrust` may have to run Play Integrity (prepare and request), so it
  /// gets a longer timeout.
  static const _ensureTrustTimeoutMs = 15000;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (signWhen != null && !signWhen!(request)) {
      return _inner.send(request); // not selected for signing → forward unchanged
    }

    // Endpoint mapped to a trust level: raise trust in the BACKGROUND (fire-and-forget), not
    // awaited before signing. `ensureTrust` may run Play Integrity (up to ~15s) and must not block
    // the request hot path. If trust is too low the server answers 403, and we raise trust and
    // resend once (below).
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
          return _inner.send(request); // sent UNSIGNED
        case OnNotReady.blockRetry:
          if (e.retryable == false) rethrow;
          await CShieldAttest.awaitReady(timeoutMs: _blockRetryWaitMs);
          // Retry exactly once (the request was never sent: signing threw before it hit the wire).
          return (await _signProceedVerify(request, body, contentType, isRetry: true)).response;
      }
    }

    // The server rejected the access token (401 invalid token) → force a refresh and retry
    // exactly once with the new token. Only an http.Request can be cloned; for any other type
    // (multipart, streamed) the 401 is returned as is.
    if (attempt.retryableInvalidToken) {
      final clone = _cloneRequest(request);
      if (clone != null && await CShieldAIP.forceRefresh()) {
        return (await _signProceedVerify(clone, body, contentType, isRetry: true)).response;
      }
    }

    // The server rejected the request for trust (403 CSHIELD_DEVICE_NOT_ALLOWED /
    // CSHIELD_TRUST_NOT_FRESH) → raise trust with fresh proof, then resend exactly once. This
    // replaces awaiting ensureTrust before signing: react to the 403 instead of blocking up front.
    if (attempt.retryableTrust) {
      final level = requiredLevel?.call(request);
      final clone = _cloneRequest(request);
      if (level != null && level != TrustLevel.unknown && clone != null) {
        EnsureTrustResult? result;
        try {
          result = await CShieldAttest.ensureTrust(level, requireFresh: true, timeoutMs: _ensureTrustTimeoutMs);
        } on CShieldException catch (e) {
          // Configuration error (requiredLevel set, but initialize got no cloudProjectNumber)
          // → surface it so the integrator can fix it.
          if (e.code == CShieldErrorCode.playIntegrityNotConfigured) rethrow;
          // Any other, transient error → let the 403 continue to the app.
        }
        if (result == EnsureTrustResult.satisfied) {
          return (await _signProceedVerify(clone, body, contentType, isRetry: true)).response;
        }
      }
    }
    return attempt.response;
  }

  /// Signs and sends the request. When verification is on, buffers the body, runs the
  /// status-aware `verifyResponse`, and rebuilds the StreamedResponse.
  ///
  /// The result also carries two flags, both `false` on a retry: `retryableInvalidToken`
  /// (401 invalid token) and `retryableTrust` (trust 403).
  ///
  /// With verification off, the response is passed through as a stream, except for a 401/403 on
  /// the first attempt: that body is buffered so the retry flags can still be computed. In that
  /// case the error body is not signature-checked; the worst a forged one can cause is a single
  /// extra refresh and resend.
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
    if (!verifyResponses) {
      // Only a first-attempt 401/403 can lead to a retry; everything else keeps streaming.
      final mayRetry = !isRetry && (streamed.statusCode == 401 || streamed.statusCode == 403);
      if (!mayRetry) return _Attempt(streamed, false, false);
    }

    final responseBytes = await streamed.stream.toBytes();
    if (verifyResponses) {
      await CShieldAIP.verifyResponse(
          statusCode: streamed.statusCode,
          path: path,
          query: request.url.query,
          headers: streamed.headers,
          body: responseBytes);
    }

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

  /// Whether a 403 was caused by trust (below the minimum, or no longer fresh), which decides
  /// whether to raise trust and resend.
  static bool _isTrustRejected(Uint8List bytes) {
    final body = utf8.decode(bytes, allowMalformed: true);
    return body.contains('CSHIELD_DEVICE_NOT_ALLOWED') || body.contains('CSHIELD_TRUST_NOT_FRESH');
  }

  /// Clones a request so it can be resent. Only an http.Request can be cloned (its bodyBytes
  /// survive `send`; the old cs-proof is overwritten when the clone is signed). Any other type
  /// (multipart, …) returns null, meaning no retry.
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

  /// Raises trust in the background. Best effort: it never blocks or fails the request, because
  /// the server is what enforces trust, and it swallows every error.
  ///
  /// A configuration error (`playIntegrityNotConfigured`: `requiredLevel` is set but `initialize`
  /// got no `cloudProjectNumber`, so Play Integrity is off) is not lost: it is surfaced by the
  /// 403 retry path in [send], where `ensureTrust(requireFresh: true)` throws and is rethrown.
  static Future<void> _ensureTrustBestEffort(TrustLevel? level) async {
    if (level == null || level == TrustLevel.unknown) return;
    try {
      await CShieldAttest.ensureTrust(level, timeoutMs: _ensureTrustTimeoutMs);
    } catch (_) {
      // Fire-and-forget: swallow everything so no unhandled async error escapes. A configuration
      // error is surfaced by the 403 retry path instead (see the doc comment above).
    }
  }

  @override
  void close() => _inner.close();

  // ── Helpers ───────────────────────────────────────────────────────────────

  /// Returns the bytes to sign and the content type to report to the normalizer.
  static (Uint8List, String) _bodyAndContentType(http.BaseRequest request) {
    if (request is http.MultipartRequest) {
      // Same as the native SDKs: only text fields are signed (files skipped),
      // sorted and JSON-encoded. Report application/json so the payload hash
      // matches the multipart text fields the server extracts. The original
      // multipart request (with files) is still sent on the wire unchanged.
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

/// Result of one sign + send + verify attempt: the rebuilt response plus the flags that say
/// whether it is worth a retry (401 invalid token / trust 403).
class _Attempt {
  final http.StreamedResponse response;
  final bool retryableInvalidToken;
  final bool retryableTrust;
  _Attempt(this.response, this.retryableInvalidToken, this.retryableTrust);
}
