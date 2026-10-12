import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:c_shield_embedded/c_shield_embedded.dart';
import 'package:c_shield_embedded/src/internal/platform/c_shield_embedded_platform_interface.dart';
import 'package:crypto/crypto.dart' as crypto;
import 'package:dio/dio.dart';
import 'package:http/io_client.dart';

/// Public API for Certificate Pinning.
///
/// Android equivalent: getSSLSocketFactory() / getTrustManager() / getSSLContext()
/// iOS equivalent: urlSession() / trustManager()
/// Flutter equivalent: createHttpClient() / createIOClient() / verifyPin()
///
/// ## Quick integration guide
///
/// ### `http` package
/// ```dart
/// await CShieldSSL.configure(pins: ['sha256/...'], hostname: 'api.example.com');
/// final client = CShieldSSL.createIOClient(); // drop-in for http.Client()
/// ```
///
/// ### Dio
/// ```dart
/// import 'package:dio/io.dart';
/// await CShieldSSL.configure(pins: ['sha256/...'], hostname: 'api.example.com');
/// dio.httpClientAdapter = IOHttpClientAdapter(
///   createHttpClient: CShieldSSL.createHttpClient,
/// );
/// ```
///
/// ### Verify a certificate independently (full CA + SPKI, native-backed)
/// ```dart
/// final trusted = await CShieldSSL.verifyPin(certDerBase64: base64Cert, host: 'api.example.com');
/// ```
/// Public API for Certificate Pinning.
///
/// Android equivalent: getSSLSocketFactory() / getTrustManager() / getSSLContext()
/// iOS equivalent: urlSession() / trustManager()
/// Flutter equivalent: createHttpClient() / createIOClient() / verifyPin()
///
/// ## Quick integration guide
///
/// ### `http` package
/// ```dart
/// await CShieldSSL.configure(pins: ['sha256/...'], hostname: 'api.example.com');
/// final client = CShieldSSL.createIOClient(); // drop-in for http.Client()
/// ```
///
/// ### Dio
/// ```dart
/// import 'package:dio/io.dart';
/// await CShieldSSL.configure(pins: ['sha256/...'], hostname: 'api.example.com');
/// dio.httpClientAdapter = IOHttpClientAdapter(
///   createHttpClient: CShieldSSL.createHttpClient,
/// );
/// ```
///
/// ### Verify a certificate independently (full CA + SPKI, native-backed)
/// ```dart
/// final trusted = await CShieldSSL.verifyPin(certDerBase64: base64Cert, host: 'api.example.com');
/// ```
class CShieldSSL {
  CShieldSSL._();

  /// Cấu hình pin theo từng host (R5 — multi-host). `null` khi chưa configure.
  static Map<String, List<String>>? _pinsByHost;

  /// Single-host convenience. Xem [configureHosts] cho nhiều host.
  ///
  /// [pins] — format `"sha256/<base64>"`, nên ≥2 (primary + backup).
  /// [hostname] — domain cần pin.
  /// [allowRuntimeUpdates] — `false` (mặc định) ⇒ native AUTO-SEAL sau configure (H-3):
  ///   gọi lại configure/updatePins sẽ ném. `true` ⇒ cho phép mutate runtime (kém an toàn).
  static Future<void> configure({
    required List<String> pins,
    required String hostname,
    bool allowRuntimeUpdates = false,
  }) => configureHosts(pinsByHost: {hostname: pins}, allowRuntimeUpdates: allowRuntimeUpdates);

  /// Cấu hình pinning cho NHIỀU host trong MỘT lần gọi (R5).
  ///
  /// Vì mặc định native auto-seal (H-3), phải khai báo TẤT CẢ host pin ở đây — gọi
  /// configure lần 2 sẽ ném (trừ khi [allowRuntimeUpdates]=true).
  ///
  /// [pinsByHost] — `host pattern → danh sách pin`. Pattern: `example.com` (đúng),
  ///   `*.example.com` (đúng 1 cấp subdomain), `**.example.com` (apex + mọi cấp).
  ///
  /// Throws [CShieldException] ([invalidArgument]) nếu rỗng/host trống/pin sai format;
  /// hoặc ([sslNotConfigured]/[nativeError]) nếu native từ chối (vd đã seal).
  static Future<void> configureHosts({
    required Map<String, List<String>> pinsByHost,
    bool allowRuntimeUpdates = false,
  }) async {
    if (pinsByHost.isEmpty) {
      throw const CShieldException(CShieldErrorCode.invalidArgument, 'pinsByHost: Must contain at least one host.');
    }
    pinsByHost.forEach((hostname, pins) {
      if (hostname.trim().isEmpty) {
        throw const CShieldException(CShieldErrorCode.invalidArgument, 'hostname: Must not be blank.');
      }
      if (pins.isEmpty) {
        throw CShieldException(CShieldErrorCode.invalidArgument, 'pins for "$hostname": Must contain at least one pin.');
      }
      for (final pin in pins) {
        if (!pin.startsWith('sha256/')) {
          throw CShieldException(CShieldErrorCode.invalidArgument, 'pins: Each pin must be in format "sha256/<base64>". Got: "$pin"');
        }
      }
    });
    await CShieldEmbeddedPlatform.instance.sslConfigure(pinsByHost: pinsByHost, allowRuntimeUpdates: allowRuntimeUpdates);
    _pinsByHost = Map.unmodifiable({for (final e in pinsByHost.entries) e.key: List<String>.unmodifiable(e.value)});
  }

  /// Updates pins (vd sau khi rotate certificate).
  ///
  /// CHỈ chạy nếu [configure]/[configureHosts] ban đầu dùng `allowRuntimeUpdates=true`;
  /// nếu không, native đã auto-seal và lời gọi này sẽ ném ([sslNotConfigured]).
  static Future<void> updatePins({required List<String> pins, required String hostname}) async {
    await CShieldEmbeddedPlatform.instance.sslUpdatePins(pins: pins, hostname: hostname);
    final merged = Map<String, List<String>>.from(_pinsByHost ?? const {});
    merged[hostname] = List.unmodifiable(pins);
    _pinsByHost = Map.unmodifiable(merged);
  }

  /// R5 — pin của host khớp cấu hình (exact / `*.` / `**.`), hoặc `null` nếu không pin.
  static List<String>? _pinsForHost(String host) {
    final map = _pinsByHost;
    if (map == null) return null;
    final exact = map[host];
    if (exact != null) return exact;
    for (final e in map.entries) {
      if (_hostMatches(host, e.key)) return e.value;
    }
    return null;
  }

  /// Khớp host theo pattern giống PinningConfig (native): exact, `*.one-level`, `**.multi`.
  static bool _hostMatches(String host, String pattern) {
    if (pattern == host) return true;
    if (pattern.startsWith('**.')) {
      final apex = pattern.substring(3);
      return host == apex || host.endsWith('.$apex');
    }
    if (pattern.startsWith('*.')) {
      final suffix = pattern.substring(2);
      if (!host.endsWith('.$suffix')) return false;
      final sub = host.substring(0, host.length - suffix.length - 1);
      return sub.isNotEmpty && !sub.contains('.'); // đúng 1 cấp subdomain
    }
    return false;
  }

  /// Returns true if pinning has been configured.
  ///
  /// Throws [CShieldException] if the underlying native call fails.
  static Future<bool> isConfigured() => CShieldEmbeddedPlatform.instance.sslIsConfigured();

  // ── createHttpClient ────────────────────────────────────────────────────

  /// Returns an [HttpClient] configured with SPKI certificate pinning.
  ///
  /// Flutter equivalent of Android's `getSSLSocketFactory()` / iOS's `urlSession()`.
  ///
  /// Uses the system [SecurityContext] (with trusted roots) so that normal
  /// CA chain validation runs first. [HttpClient.badCertificateCallback] then
  /// acts as a secondary gate: if a certificate fails system validation (e.g.
  /// self-signed or internal CA), the SPKI pin is checked as a fallback.
  ///
  /// On Android, using `SecurityContext(withTrustedRoots: false)` causes
  /// BoringSSL to abort the TLS handshake at the C layer with
  /// `CERTIFICATE_VERIFY_FAILED` before Dart's callback can fire. Keeping
  /// system roots avoids this while still rejecting any cert whose SPKI pin
  /// does not match (for non-CA-verified certs).
  ///
  /// For additional SPKI verification on CA-signed certs, call [verifyPin]
  /// after the connection is established.
  ///
  /// Throws [CShieldException] with [CShieldErrorCode.sslNotConfigured] if
  /// [configure] has not been called.
  static HttpClient createHttpClient() {
    if (_pinsByHost == null) {
      throw const CShieldException(CShieldErrorCode.sslNotConfigured, 'CShieldSSL has not been configured. Call CShieldSSL.configure() first.');
    }

    final client = HttpClient();

    // Called only when the cert fails normal CA validation (self-signed,
    // unknown CA, hostname mismatch, etc.). Returns true iff the host is pinned
    // (R5 — any configured pattern) AND the SPKI pin matches.
    client.badCertificateCallback = (X509Certificate cert, String host, int port) {
      final hostPins = _pinsForHost(host);
      if (hostPins == null) return false;
      final computed = _computeSpkiPin(cert.der);
      return computed != null && hostPins.contains(computed);
    };

    return client;
  }

  /// Returns an [IOClient] (from the `http` package) wrapping a pinned [HttpClient].
  ///
  /// Drop-in replacement for `http.Client()` — customers using the `http`
  /// package do **not** need to rewrite any request code:
  /// ```dart
  /// // Setup (once, e.g. in main()):
  /// await CShieldSSL.configure(pins: [...], hostname: 'api.example.com');
  /// final client = CShieldSSL.createIOClient();
  ///
  /// // Usage — identical to http.Client():
  /// final response = await client.get(Uri.parse('https://api.example.com/data'));
  /// ```
  ///
  /// Throws [CShieldException] with [CShieldErrorCode.sslNotConfigured] if
  /// [configure] has not been called.
  static IOClient createIOClient() => IOClient(createHttpClient());

  // ── createDioAdapter ───────────────────────────────────────────────────

  /// Returns a Dio [HttpClientAdapter] that performs requests to the configured
  /// [hostname] on the **native** side (OkHttp on Android, URLSession on iOS),
  /// where certificate pinning is enforced against the **full certificate chain**.
  ///
  /// This is the recommended adapter for Dio users and the only path that
  /// matches the standalone Android/iOS SDKs exactly: because the native layer
  /// sees the whole chain (not just the leaf, which is all `dart:io` exposes),
  /// it can match a pin at the leaf, intermediate, or root. Pinning a stable
  /// intermediate CA lets the app survive leaf-certificate rotation without an
  /// app update.
  ///
  /// Requests to other hosts are transparently delegated to a standard
  /// [IOHttpClientAdapter], so unpinned traffic is unaffected.
  ///
  /// ```dart
  /// import 'package:c_shield_embedded/c_shield_embedded.dart';
  /// import 'package:dio/dio.dart';
  ///
  /// await CShieldSSL.configure(pins: ['sha256/...'], hostname: 'api.example.com');
  ///
  /// final dio = Dio(BaseOptions(baseUrl: 'https://api.example.com'));
  /// dio.httpClientAdapter = CShieldSSL.createDioAdapter();
  /// dio.interceptors.add(const CShieldDioInterceptor());
  /// ```
  ///
  /// Buffered (non-streaming); see [CShieldNativeHttpAdapter] for limitations.
  /// For the `http` package, use [createIOClient] instead (leaf-only pinning).
  ///
  /// Throws [CShieldException] with [CShieldErrorCode.sslNotConfigured] if
  /// [configure] has not been called.
  static HttpClientAdapter createDioAdapter() {
    final map = _pinsByHost;
    if (map == null) {
      throw const CShieldException(CShieldErrorCode.sslNotConfigured, 'CShieldSSL has not been configured. Call CShieldSSL.configure() first.');
    }
    return CShieldNativeHttpAdapter(hostPatterns: map.keys.toSet());
  }

  // ── verifyPin ──────────────────────────────────────────────────────────

  /// Verifies a certificate against the configured pins using the native
  /// trust manager (system CA validation + SPKI pin check).
  ///
  /// Flutter equivalent of Android's `CShieldTrustManager.checkServerTrusted()`
  /// and iOS's `SecTrustEvaluateWithError` + SPKI check.
  ///
  /// [certDerBase64] — base64-encoded DER certificate (leaf cert from the server).
  /// [host] — hostname of the server being verified.
  ///
  /// Returns `true` if the certificate passes both system CA validation and
  /// SPKI pin verification.
  ///
  /// Typical usage with Dio or any HTTP interceptor:
  /// ```dart
  /// final certBase64 = base64.encode(peerCertificateDerBytes);
  /// final trusted = await CShieldSSL.verifyPin(certDerBase64: certBase64, host: 'api.example.com');
  /// if (!trusted) throw Exception('Certificate pin mismatch');
  /// ```
  ///
  /// Throws [CShieldException] if the underlying native call fails (e.g.
  /// malformed [certDerBase64]).
  static Future<bool> verifyPin({required String certDerBase64, required String host}) => CShieldEmbeddedPlatform.instance.sslCheckServerTrusted(certDerBase64: certDerBase64, host: host);

  // ── SPKI computation (Dart-level) ───────────────────────────────────────

  static String? _computeSpkiPin(Uint8List derCert) {
    final spki = _extractSpki(derCert);
    if (spki == null) return null;
    final digest = crypto.sha256.convert(spki);
    return 'sha256/${base64.encode(digest.bytes)}';
  }

  /// Extracts the SubjectPublicKeyInfo (SPKI) SEQUENCE from a DER-encoded X.509 cert.
  ///
  /// X.509 DER structure navigated:
  ///   Certificate SEQUENCE
  ///     TBSCertificate SEQUENCE
  ///       version [0] EXPLICIT (optional)
  ///       serialNumber INTEGER
  ///       signature AlgorithmIdentifier
  ///       issuer Name
  ///       validity Validity
  ///       subject Name
  ///       subjectPublicKeyInfo SubjectPublicKeyInfo  ← extracted
  static Uint8List? _extractSpki(Uint8List der) {
    try {
      var i = 0;

      // Certificate SEQUENCE — enter content
      if (der[i++] != 0x30) return null;
      final (cContent, _) = _readLength(der, i);
      i = cContent;

      // TBSCertificate SEQUENCE — enter content
      if (der[i++] != 0x30) return null;
      final (tbsContent, _) = _readLength(der, i);
      i = tbsContent;

      // version [0] EXPLICIT — skip if present
      if (der[i] == 0xA0) i = _skipTlv(der, i);

      // serialNumber, signature, issuer, validity, subject — skip
      i = _skipTlv(der, i);
      i = _skipTlv(der, i);
      i = _skipTlv(der, i);
      i = _skipTlv(der, i);
      i = _skipTlv(der, i);

      // subjectPublicKeyInfo SEQUENCE — capture bytes
      final spkiStart = i;
      final spkiEnd = _skipTlv(der, i);
      return der.sublist(spkiStart, spkiEnd);
    } catch (_) {
      return null;
    }
  }

  /// Given offset [i] pointing at a DER length field, returns
  /// `(contentOffset, length)` where `contentOffset` is the first byte of content.
  static (int, int) _readLength(Uint8List data, int i) {
    final b = data[i];
    if (b < 0x80) return (i + 1, b);
    final n = b & 0x7F;
    var len = 0;
    for (var j = 1; j <= n; j++) {
      len = (len << 8) | data[i + j];
    }
    return (i + 1 + n, len);
  }

  /// Given offset [i] pointing at a DER TLV tag byte, returns the offset
  /// of the next TLV (i.e. skips this entire tag-length-value).
  static int _skipTlv(Uint8List data, int i) {
    i++; // tag
    final (contentOffset, length) = _readLength(data, i);
    return contentOffset + length;
  }
}
