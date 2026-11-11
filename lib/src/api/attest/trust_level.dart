/// Mức độ tin cậy thiết bị (thang L0–L5, khớp native `TrustLevel.kt` + BE `trust_level.go`) mà bên
/// tích hợp dùng với [CShieldAttest.ensureTrust] / [CShieldAttest.currentTrustLevel].
///
///  - L0 UNTRUSTED · L1 WEAK · L2 BASIC · L3 PARTIAL (một trụ mạnh, trụ kia chưa rõ — vd TEE +
///    Play Integrity chưa có) · L4 HARDWARE (TEE + PI đạt) · L5 STRONG (StrongBox + PI mạnh).
///  - [unknown]: chưa có token / chưa đăng ký → coi như thấp nhất khi so [atLeast].
///
/// ⚠️ Giá trị này đọc từ access token thiết bị đang giữ, **chỉ để điều hướng phía client** (quyết
/// định có cần nâng trust trước khi gọi API nhạy). Chốt bảo mật vẫn ở SERVER (verify token + ngưỡng
/// trust theo route). Client không thể giả mạo mức cao hơn vì token do BE ký.
///
/// ⚠️ iOS tối đa **L4** (Secure Enclave ánh xạ vào hàng "TEE", không có StrongBox) — đặt ngưỡng
/// [l5] sẽ chặn sạch iOS.
enum TrustLevel {
  unknown(-1, 'UNKNOWN'),
  l0(0, 'L0'),
  l1(1, 'L1'),
  l2(2, 'L2'),
  l3(3, 'L3'),
  l4(4, 'L4'),
  l5(5, 'L5');

  const TrustLevel(this.rank, this.id);

  /// Thứ hạng để so sánh ngưỡng ([unknown] = -1, luôn nhỏ hơn mọi mức hợp lệ).
  final int rank;

  /// Tên cross method-channel (khớp `TrustLevel.name` phía native).
  final String id;

  /// `true` nếu mức này ≥ [other] theo thang L0–L5.
  bool atLeast(TrustLevel other) => rank >= other.rank;

  /// Map tên native ("L0".."L5"/"UNKNOWN", không phân biệt hoa thường) → [TrustLevel];
  /// rỗng/không khớp → [unknown].
  static TrustLevel fromId(String? value) {
    final v = (value ?? '').trim().toUpperCase();
    return values.firstWhere((e) => e.id == v, orElse: () => unknown);
  }
}
