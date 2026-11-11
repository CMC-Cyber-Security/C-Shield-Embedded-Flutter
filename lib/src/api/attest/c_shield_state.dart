/// Trạng thái sẵn sàng của attestation (khớp native `CShieldState.kt`) — bên tích hợp đọc để xử lý
/// tất định khi attest CHƯA xong, thay vì fail-closed mờ.
///
///  - [initializing]: đang register/refresh nền — chưa có token dùng được. Tạm thời, nên chờ/retry.
///  - [ready]: có access token + hardware key hợp lệ — ký request được.
///  - [degraded]: sẵn sàng nhưng trust thấp (L0/L1) — một số endpoint có thể bị server từ chối.
///  - [unavailable]: máy không hỗ trợ attestation, đăng ký bị từ chối vĩnh viễn, hoặc nền tảng chưa
///    hỗ trợ attest v2 (iOS) — ĐỪNG retry.
enum CShieldState {
  initializing('INITIALIZING'),
  ready('READY'),
  degraded('DEGRADED'),
  unavailable('UNAVAILABLE');

  const CShieldState(this.id);

  /// Tên cross method-channel (khớp `CShieldState.name` phía native).
  final String id;

  /// Map tên native → [CShieldState]; không khớp → [unavailable] (fail-closed).
  static CShieldState fromId(String? value) {
    final v = (value ?? '').trim().toUpperCase();
    return values.firstWhere((e) => e.id == v, orElse: () => unavailable);
  }
}
