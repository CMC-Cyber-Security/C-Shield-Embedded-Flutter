import '../../internal/platform/c_shield_embedded_platform_interface.dart';

/// Anti-keylogger guard for the host app. Detects the two keystroke-capture
/// vectors an Android app can observe:
///
///  1. a third-party / untrusted keyboard (IME) set as the active input method,
///  2. untrusted accessibility services that can read typed text.
///
/// It is **auto-started** by `CShieldEmbedded.initialize(...)` and watches for
/// IME / accessibility changes at runtime. Detections arrive on
/// `CShieldEmbedded.events` as `ThirdPartyKeyboardDetected` /
/// `SuspiciousAccessibilityServiceDetected`.
///
/// Unlike iOS (which can refuse a third-party keyboard extension), Android cannot
/// block the system keyboard the user chose — the guard only detects and reports.
///
/// Both platforms emit `ThirdPartyKeyboardDetected`. iOS does **not** emit
/// `SuspiciousAccessibilityServiceDetected` (no such concept), and [configure] /
/// [runCheck] are no-ops there (iOS has no keyboard allowlist and detects
/// automatically) — they still resolve so shared code is portable.
class CShieldAntiKeylogger {
  CShieldAntiKeylogger._();

  /// Sets the trust allowlists. Call [runCheck] afterwards to re-evaluate now.
  ///
  /// - [trustSystemKeyboards]: trust any IME shipped as a system app (default true).
  /// - [trustedKeyboardPackages]: reputable third-party keyboard packages to trust.
  ///   An **empty** list keeps the native default (Gboard / Samsung / SwiftKey).
  /// - [trustedAccessibilityPackages]: accessibility-service packages to treat as legitimate.
  static Future<void> configure({
    bool trustSystemKeyboards = true,
    List<String> trustedKeyboardPackages = const [],
    List<String> trustedAccessibilityPackages = const [],
  }) {
    return CShieldEmbeddedPlatform.instance.antiKeyloggerConfigure(
      trustSystemKeyboards: trustSystemKeyboards,
      trustedKeyboardPackages: trustedKeyboardPackages,
      trustedAccessibilityPackages: trustedAccessibilityPackages,
    );
  }

  /// Re-evaluates the current keyboard / accessibility posture on demand (e.g.
  /// when a sensitive screen resumes). Re-emits any detection over the events stream.
  static Future<void> runCheck() {
    return CShieldEmbeddedPlatform.instance.antiKeyloggerRunCheck();
  }
}
