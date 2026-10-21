import '../../internal/platform/c_shield_embedded_platform_interface.dart';

/// Runtime anti-overlay / anti-tapjacking guard for the host app's own
/// sensitive screens (login, OTP, money transfer…).
///
/// Call [protect] once the sensitive screen is on top; the native guard wraps
/// the host Activity's window and inspects every touch for Android's
/// "window is obscured" flags — the framework-level signal that another app's
/// window is drawn over yours. Fully-obscured taps are swallowed (tapjacking
/// defense) unless [protect] is called with `blockObscuredTouches: false`.
///
/// Overlay/clear notifications arrive on [CShieldEmbedded.events] as
/// `OverlayDetected` / `OverlayCleared`.
///
/// Android-only (relies on `MotionEvent` obscured flags); the calls reject /
/// are not implemented on iOS.
class CShieldAntiOverlay {
  CShieldAntiOverlay._();

  /// Hardens the host's current screen against overlay/tapjacking.
  ///
  /// When [blockObscuredTouches] is true (default), touches arriving while the
  /// window is fully obscured are dropped; when false the guard only observes
  /// and still emits `OverlayDetected`.
  static Future<void> protect({bool blockObscuredTouches = true}) {
    return CShieldEmbeddedPlatform.instance.antiOverlayProtect(blockObscuredTouches: blockObscuredTouches);
  }

  /// Removes the guard installed by [protect], restoring normal touch handling.
  static Future<void> unprotect() {
    return CShieldEmbeddedPlatform.instance.antiOverlayUnprotect();
  }
}
