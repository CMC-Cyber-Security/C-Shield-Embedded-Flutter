import '../../internal/platform/c_shield_embedded_platform_interface.dart';

/// Behavioral Touch Guard (BTG): runtime detection of machine-generated input on
/// the host app's own sensitive screens — auto-clickers, ADB `input tap`,
/// UiAutomator, and root-level `/dev/input` injection.
///
/// Call [protect] once the sensitive screen is on top; the native guard wraps the
/// host Activity's window and analyses each touch (per-tap properties + behaviour
/// over recent taps). When the risk score crosses the threshold a
/// `SuspiciousTouchDetected` event arrives on [CShieldEmbedded.events]; the touch
/// is still delivered unless [protect] is called with `blockWhenDetected: true`.
/// Recovery is reported as `TouchGuardCleared`.
///
/// It does not identify *who* is tapping (that would be behavioural biometrics);
/// it only judges human vs synthetic.
///
/// Android-only (relies on Android `MotionEvent`s); the calls are not implemented
/// on iOS.
class CShieldBehavioralTouchGuard {
  CShieldBehavioralTouchGuard._();

  /// Hardens the host's current screen against machine-generated input.
  ///
  /// @param riskThreshold score (0..100) at or above which a touch is reported.
  ///   Omit to use the native default.
  /// @param blockWhenDetected when true, a suspicious touch is swallowed in
  ///   addition to emitting the event. Default false (observe and report only).
  /// @param includeAccessibilitySignal when true, a third-party accessibility
  ///   service adds a weak contextual signal. Off by default (e.g. TalkBack would
  ///   otherwise contribute).
  static Future<void> protect({
    int? riskThreshold,
    bool blockWhenDetected = false,
    bool includeAccessibilitySignal = false,
  }) {
    return CShieldEmbeddedPlatform.instance.btgProtect(
      riskThreshold: riskThreshold,
      blockWhenDetected: blockWhenDetected,
      includeAccessibilitySignal: includeAccessibilitySignal,
    );
  }

  /// Removes the guard installed by [protect], restoring normal touch handling.
  static Future<void> unprotect() {
    return CShieldEmbeddedPlatform.instance.btgUnprotect();
  }
}
