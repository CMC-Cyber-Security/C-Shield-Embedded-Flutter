import 'package:c_shield_embedded/src/api/attest/c_shield_state.dart';
import 'package:c_shield_embedded/src/api/attest/trust_level.dart';

/// Listen via [CShieldEmbedded.events].
sealed class CShieldEvent {
  const CShieldEvent();

  factory CShieldEvent.fromMap(Map<Object?, Object?> map) {
    final event = map['event'];
    switch (event) {
      case 'onLicenseRenewed':
        return LicenseRenewed(map['newJwt'] as String);
      case 'onLicenseRevoked':
        return const LicenseRevoked();
      case 'onAttestStateChanged':
        return AttestStateChanged(
          state: CShieldState.fromId(map['state'] as String?),
          trustLevel: TrustLevel.fromId(map['trustLevel'] as String?),
          lastError: map['lastError'] as String?,
        );
      default:
        throw ArgumentError('Unknown CShield event: $event');
    }
  }
}

/// The license was renewed; [newJwt] is the refreshed token.
class LicenseRenewed extends CShieldEvent {
  final String newJwt;

  const LicenseRenewed(this.newJwt);
}

/// The license was revoked by the server.
class LicenseRevoked extends CShieldEvent {
  const LicenseRevoked();
}

/// Trạng thái attestation vừa đổi (register/refresh nền chạy xong, trust được nâng, hoặc đăng ký bị
/// từ chối vĩnh viễn). Native phát NGAY sự kiện đầu tiên với trạng thái hiện tại lúc đăng ký.
///
/// Lắng nghe qua [CShieldAttest.stateChanges] (đã lọc sẵn) hoặc [CShieldEmbedded.events].
class AttestStateChanged extends CShieldEvent {
  /// Trạng thái sẵn sàng mới.
  final CShieldState state;

  /// Mức trust tại thời điểm đổi trạng thái (đọc từ access token đang giữ).
  final TrustLevel trustLevel;

  /// Mã lỗi ổn định gần nhất (xem [CShieldAttest.lastError]); `null` nếu chưa có lỗi.
  final String? lastError;

  const AttestStateChanged({required this.state, required this.trustLevel, this.lastError});

  @override
  String toString() => 'AttestStateChanged(state: ${state.id}, trustLevel: ${trustLevel.id}, lastError: $lastError)';
}
