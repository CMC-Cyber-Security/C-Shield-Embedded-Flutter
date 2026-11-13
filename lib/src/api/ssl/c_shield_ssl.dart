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
/// ## Quick integration guide
///
/// ### Dio (recommended — native transport, pins matched against the whole chain)
/// ```dart
/// await CShieldSSL.configure(pins: ['sha256/...'], hostname: 'api.example.com');
/// dio.httpClientAdapter = CShieldSSL.createDioAdapter();
/// ```
///
/// ### `http` package (leaf-only, pure Dart)
/// ```dart
/// await CShieldSSL.configure(pins: ['sha256/...'], hostname: 'api.example.com');
/// final client = CShieldSSL.createIOClient(); // drop-in for http.Client()
/// ```
///
/// ### Verify a certificate independently
/// ```dart
/// final trusted = await CShieldSSL.verifyPin(certDerBase64: base64Cert, host: 'api.example.com');
/// ```
class CShieldSSL {
  CShieldSSL._();

  /// The configured pins per host pattern. `null` until pinning is configured.
  static Map<String, List<String>>? _pinsByHost;

  /// Single-host convenience. See [configureHosts] for several hosts.
  ///
  /// - [pins]: in the format `"sha256/<base64>"`. Provide at least two
  ///   (primary and backup).
  /// - [hostname]: the host to pin.
  /// - [allowRuntimeUpdates]: `false` (the default) makes the native side
  ///   **seal** the pin set once it is configured, so a later [updatePins]
  ///   throws. `true` allows the pins to be changed at runtime, which is less
  ///   strict.
  static Future<void> configure({
    required List<String> pins,
    required String hostname,
    bool allowRuntimeUpdates = false,
  }) => configureHosts(pinsByHost: {hostname: pins}, allowRuntimeUpdates: allowRuntimeUpdates);

  /// Configures pinning for **several** hosts in **one** call.
  ///
  /// Because the native side seals the pin set by default, **every** pinned
  /// host must be declared here: the pins cannot be extended later unless
  /// [allowRuntimeUpdates] is `true`. Calling this again once pinning is
  /// configured does not throw; the native configuration is kept as it is.
  ///
  /// [pinsByHost] maps a host pattern to its list of pins. Patterns:
  /// `example.com` (exact), `*.example.com` (exactly one subdomain level),
  /// `**.example.com` (the apex and any subdomain depth).
  ///
  /// Throws [CShieldException] with [CShieldErrorCode.invalidArgument] if the
  /// map is empty, a host is blank, a pin list is empty, or a pin is not in
  /// the `sha256/` format; or with [CShieldErrorCode.sslNotConfigured] /
  /// [CShieldErrorCode.nativeError] if the native side rejects the
  /// configuration.
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
    // Warm relaunch with the process kept alive (for example by a foreground service): native
    // pinning was configured and sealed on the previous run, and the seal lives as long as the
    // process. The new Dart isolate calls configure again, the native side would reject it
    // (ssl_not_configured), and the error would escape main() BEFORE runApp(), leaving the app
    // stuck on the splash screen. So when pinning is already configured, treat the call as
    // idempotent: only restore the Dart-side map for the new isolate and do NOT call native again.
    if (!await isConfigured()) {
      await CShieldEmbeddedPlatform.instance.sslConfigure(pinsByHost: pinsByHost, allowRuntimeUpdates: allowRuntimeUpdates);
    }
    _pinsByHost = Map.unmodifiable({for (final e in pinsByHost.entries) e.key: List<String>.unmodifiable(e.value)});
  }

  /// Replaces the pins of [hostname], for example after a certificate
  /// rotation.
  ///
  /// Works only if [configure] / [configureHosts] was called with
  /// `allowRuntimeUpdates: true`. Otherwise the native pin set is sealed and
  /// this call throws [CShieldException] with
  /// [CShieldErrorCode.sslNotConfigured].
  static Future<void> updatePins({required List<String> pins, required String hostname}) async {
    await CShieldEmbeddedPlatform.instance.sslUpdatePins(pins: pins, hostname: hostname);
    final merged = Map<String, List<String>>.from(_pinsByHost ?? const {});
    merged[hostname] = List.unmodifiable(pins);
    _pinsByHost = Map.unmodifiable(merged);
  }

  /// The UNION of the pins of EVERY pattern that matches the host (exact / `*.` / `**.`), or
  /// `null` if the host is not pinned. Mirrors the native `PinningConfig.pinsFor` (Android and
  /// iOS), so Dart and native never disagree.
  static List<String>? _pinsForHost(String rawHost) {
    final map = _pinsByHost;
    if (map == null) return null;
    final host = _normalize(rawHost);
    final matched = <String>{};
    var any = false;
    for (final e in map.entries) {
      if (_hostMatches(host, _normalize(e.key))) {
        any = true;
        matched.addAll(e.value.map((p) => p.trim()));
      }
    }
    return any ? matched.toList(growable: false) : null;
  }

  static String _normalize(String host) {
    var h = host.trim().toLowerCase();
    while (h.endsWith('.')) {
      h = h.substring(0, h.length - 1);
    }
    return h;
  }

  /// Matches a host against a pattern the same way the native `PinningConfig` does: exact,
  /// `*.` (one level), `**.` (any depth).
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
      return sub.isNotEmpty && !sub.contains('.'); // exactly one subdomain level
    }
    return false;
  }

  /// Returns true if pinning has been configured.
  ///
  /// Throws [CShieldException] if the underlying native call fails.
  static Future<bool> isConfigured() => CShieldEmbeddedPlatform.instance.sslIsConfigured();

  // ── createHttpClient ────────────────────────────────────────────────────

  /// Returns a `dart:io` [HttpClient] with leaf-only SPKI pinning, done in
  /// pure Dart.
  ///
  /// Uses the system [SecurityContext] (with trusted roots), so normal CA
  /// chain validation runs first. [HttpClient.badCertificateCallback] is a
  /// secondary gate: it fires **only** when a certificate fails system
  /// validation (self-signed, internal CA, …), and then accepts the
  /// certificate only if the host is pinned and the leaf's SPKI pin matches.
  ///
  /// **Limitation:** a certificate that chains to a CA the device trusts,
  /// including a CA the user installed, passes without the pin being checked,
  /// and intermediate pins never match because only the leaf is visible. For
  /// sensitive traffic use [createDioAdapter] instead.
  ///
  /// On Android, `SecurityContext(withTrustedRoots: false)` makes BoringSSL
  /// abort the TLS handshake with `CERTIFICATE_VERIFY_FAILED` before Dart's
  /// callback can fire, which is why the system roots are kept.
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
    // (by any configured pattern) AND the SPKI pin matches.
    client.badCertificateCallback = (X509Certificate cert, String host, int port) {
      final hostPins = _pinsForHost(host);
      if (hostPins == null) return false;
      final computed = _computeSpkiPin(cert.der);
      return computed != null && hostPins.contains(computed);
    };

    return client;
  }

  /// Returns an [IOClient] (from the `http` package) wrapping the pinned
  /// [HttpClient] of [createHttpClient], with the same leaf-only limitation.
  ///
  /// Drop-in replacement for `http.Client()` — apps using the `http` package
  /// do **not** need to rewrite any request code:
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

  /// Returns a Dio [HttpClientAdapter] that performs HTTPS requests to the
  /// configured hosts on the **native** side (OkHttp on Android, URLSession on
  /// iOS), where certificate pinning is enforced against the **full
  /// certificate chain**.
  ///
  /// This is the recommended adapter for Dio users and the only path that
  /// matches the standalone Android/iOS SDKs exactly: because the native layer
  /// sees the whole chain (not just the leaf, which is all `dart:io` exposes),
  /// a pin can match the leaf or an intermediate. Pinning a stable
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
  /// dio.interceptors.add(CShieldDioInterceptor(dio: dio));
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

  /// Verifies a single certificate against the pins configured for [host],
  /// on the native side.
  ///
  /// - [certDerBase64]: the base64-encoded DER certificate (the server's leaf
  ///   certificate).
  /// - [host]: the hostname of the server being verified.
  ///
  /// Dart can only hand over the leaf certificate, so there is no chain for a
  /// full system CA validation. The native side checks the certificate's
  /// validity period and hostname, then compares the **leaf's** SPKI pin with
  /// the pins of [host]; intermediate pins do not match here. Treat this as a
  /// secondary check, not as the primary pinning mechanism (that is
  /// [createDioAdapter]).
  ///
  /// Returns `true` if the certificate is accepted, `false` otherwise.
  ///
  /// Typical usage in a custom client or a WebSocket:
  /// ```dart
  /// final certBase64 = base64.encode(peerCertificateDerBytes);
  /// final trusted = await CShieldSSL.verifyPin(certDerBase64: certBase64, host: 'api.example.com');
  /// if (!trusted) throw Exception('Certificate pin mismatch');
  /// ```
  ///
  /// Throws [CShieldException] with [CShieldErrorCode.sslNotConfigured] if
  /// pinning is not configured, or with another code if the native call fails.
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
