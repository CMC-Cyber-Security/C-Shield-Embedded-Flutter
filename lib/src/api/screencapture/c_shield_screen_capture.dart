import '../../internal/platform/c_shield_embedded_platform_interface.dart';

/// Screen capture guard for the host app. iOS-only.
///
/// Detection is auto-started by `CShieldEmbedded.initialize(...)`: recording or
/// AirPlay mirroring arrives on `CShieldEmbedded.events` as `ScreenCaptureDetected`.
/// The SDK shows no warning itself, so the app decides how to react.
class CShieldScreenCapture {
  CShieldScreenCapture._();

  /// Blacks out the app in recordings, screenshots and mirroring; the app stays usable.
  /// Applies to the whole app, is idempotent and cannot be turned off.
  static Future<void> enableProtection() {
    return CShieldEmbeddedPlatform.instance.screenCaptureEnableProtection();
  }
}
