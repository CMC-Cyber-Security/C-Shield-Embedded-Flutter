/// Kết quả của [CShieldAttest.ensureTrust] (khớp native `EnsureTrustResult.kt`) — bên tích hợp đọc
/// để quyết định cho đi tiếp luồng nhạy hay chặn/hạ cấp.
///
///  - [satisfied]: đã đạt mức trust yêu cầu (và tươi nếu `requireFresh`). Cho đi tiếp.
///  - [insufficient]: đã thử nâng nhưng thiết bị không đạt (vd máy chỉ software / không GMS → Play
///    Integrity không lên nổi L4). Bên tích hợp tự quyết chặn hay hạ cấp tính năng.
///  - [rateLimited]: Play Integrity bị giới hạn tần suất/quota — tạm thời, thử lại sau. Trust hiện
///    tại KHÔNG bị hạ.
///  - [timeout]: quá `timeoutMs` trước khi nâng xong — tạm thời, thử lại sau.
///  - [unavailable]: attestation không khả dụng vĩnh viễn (chưa init / thiếu license / thiết bị
///    hoặc nền tảng không hỗ trợ) — đừng retry.
enum EnsureTrustResult {
  satisfied('SATISFIED'),
  insufficient('INSUFFICIENT'),
  rateLimited('RATE_LIMITED'),
  timeout('TIMEOUT'),
  unavailable('UNAVAILABLE');

  const EnsureTrustResult(this.id);

  /// Tên cross method-channel (khớp `EnsureTrustResult.name` phía native).
  final String id;

  /// Map tên native → [EnsureTrustResult]; không khớp → [unavailable] (fail-closed).
  static EnsureTrustResult fromId(String? value) {
    final v = (value ?? '').trim().toUpperCase();
    return values.firstWhere((e) => e.id == v, orElse: () => unavailable);
  }
}
