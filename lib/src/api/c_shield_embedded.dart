import '../internal/platform/c_shield_embedded_platform_interface.dart';
import 'event/c_shield_event.dart';

class CShieldEmbedded {
  CShieldEmbedded._();

  /// Loads the native library and starts the SDK. Call once, as early as
  /// possible in `main()`.
  ///
  /// [cloudProjectNumber]: số hiệu Google Cloud project (cho Play Integrity), dạng **chuỗi số**
  /// (vd `"970898117522"`). Dùng String để tránh bẫy số 64-bit khi bắc cầu. **Chỉ Android dùng**
  /// (Play Integrity); **iOS bỏ qua** (App Attest không cần).
  ///
  /// **`null`/không truyền = KHÔNG dùng Play Integrity** (bên tích hợp chủ động): Android chạy
  /// KA-only, bỏ warm-up, không gửi `cloud_project_number` lên BE; khi đó gọi [ensureTrust] (trực
  /// tiếp hoặc qua interceptor `requiredLevel`) sẽ ném [CShieldException] code
  /// `play_integrity_not_configured`. Thiết bị vẫn ký request bình thường, chỉ không elevate trust.
  /// Truyền chuỗi KHÁC rỗng nhưng không phải số nguyên dương → native ném lỗi (fail-fast typo).
  ///
  /// `environment` / backend URL KHÔNG truyền ở đây — native lấy từ injected params / default theo
  /// biến thể AAR.
  static Future<void> initialize({
    required String license,
    String? cloudProjectNumber,
  }) async {
    await CShieldEmbeddedPlatform.instance
        .initialize(license: license, cloudProjectNumber: cloudProjectNumber);
  }

  /// Broadcast stream of native license lifecycle events [CShieldEvent].
  static Stream<CShieldEvent> get events => CShieldEmbeddedPlatform.instance.events;
}
