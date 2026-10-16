import '../internal/platform/c_shield_embedded_platform_interface.dart';
import 'event/c_shield_event.dart';

class CShieldEmbedded {
  CShieldEmbedded._();

  /// Loads the native library and starts the SDK. Call once, as early as
  /// possible in `main()`.
  ///
  /// Attest v2 config (environment / cloud project / backend URL) KHÔNG truyền ở đây —
  /// native lấy từ injected params (portal cấp lúc inject), hoặc default theo biến thể AAR.
  static Future<void> initialize({required String license}) async {
    await CShieldEmbeddedPlatform.instance.initialize(license: license);
  }

  /// Broadcast stream of native license lifecycle events [CShieldEvent].
  static Stream<CShieldEvent> get events => CShieldEmbeddedPlatform.instance.events;
}
