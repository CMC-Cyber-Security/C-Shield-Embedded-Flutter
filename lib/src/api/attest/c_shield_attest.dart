import 'package:c_shield_embedded/src/api/aip/c_shield_aip.dart';
import 'package:c_shield_embedded/src/api/attest/c_shield_state.dart';
import 'package:c_shield_embedded/src/api/attest/ensure_trust_result.dart';
import 'package:c_shield_embedded/src/api/attest/trust_level.dart';
import 'package:c_shield_embedded/src/api/event/c_shield_event.dart';
import 'package:c_shield_embedded/src/internal/platform/c_shield_embedded_platform_interface.dart';

/// Attestation v2 — thiết bị tự chứng minh danh tính & độ an toàn bằng phần cứng bảo mật
/// (Android: Key Attestation TEE/StrongBox + Play Integrity), đổi lấy access token có **trust
/// level** do BE ký. Server verify token offline (JWKS) + ngưỡng trust theo route.
///
/// ## Mô hình "rẻ mặc định, đắt theo yêu cầu"
/// Enroll/refresh thường chạy **KA-only / keep-trust** → KHÔNG tốn quota Play Integrity → đa số máy
/// thật (TEE) dừng ở **L3**. Muốn **L4+** cho luồng nhạy thì bên tích hợp **chủ động** gọi
/// [ensureTrust] trước — khi đó SDK mới chạy Play Integrity (tốn 1 lượt quota).
///
/// ## Dùng thế nào
/// ```dart
/// // 1) Khi vào màn nhạy (thanh toán) — gọi TRƯỚC khi call API:
/// final r = await CShieldAttest.ensureTrust(TrustLevel.l4);
/// switch (r) {
///   case EnsureTrustResult.satisfied:    await goPayment();
///   case EnsureTrustResult.insufficient: block('Thiết bị chưa đạt mức an toàn yêu cầu');
///   case EnsureTrustResult.rateLimited:
///   case EnsureTrustResult.timeout:      retryLater();
///   case EnsureTrustResult.unavailable:  notSupported();
/// }
///
/// // 2) Thao tác CỰC nhạy (route đặt maxTrustAgeSeconds) — cần bằng chứng TƯƠI:
/// await CShieldAttest.ensureTrust(TrustLevel.l4, requireFresh: true);
/// ```
///
/// Server trả `CSHIELD_DEVICE_NOT_ALLOWED` (403) ⇒ trust chưa đủ → `ensureTrust(mức)`;
/// `CSHIELD_TRUST_NOT_FRESH` (403) ⇒ trust đủ nhưng cũ → `ensureTrust(mức, requireFresh: true)`.
///
/// Nền tảng chưa hỗ trợ attest v2 (iOS hiện tại) → mọi hàm trả giá trị "không khả dụng"
/// ([CShieldState.unavailable] / [TrustLevel.unknown] / [EnsureTrustResult.unavailable]) thay vì
/// ném lỗi, để app dùng chung một luồng cho cả hai nền tảng.
class CShieldAttest {
  CShieldAttest._();

  /// Trạng thái attestation hiện tại. Chưa init / thiếu license → [CShieldState.unavailable].
  static Future<CShieldState> state() => CShieldEmbeddedPlatform.instance.attestState();

  /// Mã lỗi ỔN ĐỊNH gần nhất của luồng đăng ký/làm mới (`device_blocked`, `challenge_rejected`,
  /// `attestation_not_enabled`, `device_unsupported`, `attestation_rejected`, `key_already_bound`,
  /// `transport_auth`, `network`, `rate_limited`…), hoặc `null` nếu chưa có lỗi.
  ///
  /// Khi [state] = [CShieldState.unavailable] đây là LÝ DO vĩnh viễn (hiển thị/thông báo phù hợp);
  /// khi [CShieldState.initializing] là lý do tạm thời đang được retry nền.
  static Future<String?> lastError() => CShieldEmbeddedPlatform.instance.attestLastError();

  /// Chờ tới khi sẵn sàng (hoặc hết [timeoutMs]), trả [CShieldState] cuối. Dùng khi app muốn chặn
  /// màn hình chờ attest xong thay vì để request đầu tiên fail.
  static Future<CShieldState> awaitReady({int timeoutMs = 8000}) =>
      CShieldEmbeddedPlatform.instance.attestAwaitReady(timeoutMs: timeoutMs);

  /// Mức trust hiện tại (đọc từ access token thiết bị đang giữ). Chưa init/đăng ký →
  /// [TrustLevel.unknown]. CHỈ để điều hướng phía client; chốt bảo mật vẫn ở server.
  static Future<TrustLevel> currentTrustLevel() => CShieldEmbeddedPlatform.instance.attestCurrentTrustLevel();

  /// Đảm bảo thiết bị đạt trust ≥ [minLevel] TRƯỚC khi vào luồng nhạy (API cần L4+).
  ///
  ///  - đã đủ trust + không [requireFresh] → [EnsureTrustResult.satisfied] ngay (0 Play Integrity).
  ///  - thiếu trust, hoặc [requireFresh] = `true` (API cực nhạy, cần bằng chứng PI tại thời điểm
  ///    thao tác) → nâng bằng refresh CÓ Play Integrity (tốn quota PI).
  ///
  /// [timeoutMs] cần rộng (mặc định 15s) vì có thể phải chạy Play Integrity (prepare + request).
  /// Quyết định cuối (chặn hay cho qua) vẫn do server + bên tích hợp.
  static Future<EnsureTrustResult> ensureTrust(
    TrustLevel minLevel, {
    bool requireFresh = false,
    int timeoutMs = 15000,
  }) {
    assert(minLevel != TrustLevel.unknown, 'ensureTrust cần một mức L0–L5, không phải TrustLevel.unknown');
    return CShieldEmbeddedPlatform.instance
        .attestEnsureTrust(minLevel: minLevel, requireFresh: requireFresh, timeoutMs: timeoutMs);
  }

  /// Chủ động refresh access token NGAY khi server từ chối token hiện tại (401
  /// `CSHIELD_INVALID_ACCESS_TOKEN`). Trả `true` nếu sau đó đã sẵn sàng (có token mới).
  ///
  /// Các interceptor của SDK đã tự làm việc này 1 lần/request — chỉ gọi tay khi tự dựng HTTP client.
  static Future<bool> forceRefresh({int timeoutMs = 5000}) => CShieldAIP.forceRefresh(timeoutMs: timeoutMs);

  /// Luồng đổi trạng thái attestation (native đẩy lên qua EventChannel). Phát NGAY trạng thái hiện
  /// tại khi native đăng ký listener, nên không cần poll [state].
  ///
  /// ```dart
  /// CShieldAttest.stateChanges.listen((e) => setState(() => _state = e.state));
  /// ```
  static Stream<AttestStateChanged> get stateChanges =>
      CShieldEmbeddedPlatform.instance.events.where((e) => e is AttestStateChanged).cast<AttestStateChanged>();
}
