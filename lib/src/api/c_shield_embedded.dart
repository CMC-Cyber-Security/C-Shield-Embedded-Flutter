import '../internal/platform/c_shield_embedded_platform_interface.dart';
import 'event/c_shield_event.dart';

class CShieldEmbedded {
  CShieldEmbedded._();

  /// Loads the native library and starts the SDK. Call once, as early as
  /// possible in `main()`.
  ///
  /// [cloudProjectNumber]: số hiệu Google Cloud project (cho Play Integrity), dạng **chuỗi số**
  /// (vd `"970898117522"`). Dùng String để tránh bẫy số 64-bit khi bắc cầu. **Chỉ Android dùng**
  /// (Play Integrity); **iOS bỏ qua** (App Attest không cần). Rỗng/không phải số → native ném lỗi.
  ///
  /// `environment` / backend URL KHÔNG truyền ở đây — native lấy từ injected params / default theo
  /// biến thể AAR.
  static Future<void> initialize({
    required String license,
    required String cloudProjectNumber,
  }) async {
    await CShieldEmbeddedPlatform.instance
        .initialize(license: license, cloudProjectNumber: cloudProjectNumber);
  }

  /// Broadcast stream of native license lifecycle events [CShieldEvent].
  static Stream<CShieldEvent> get events => CShieldEmbeddedPlatform.instance.events;
}
