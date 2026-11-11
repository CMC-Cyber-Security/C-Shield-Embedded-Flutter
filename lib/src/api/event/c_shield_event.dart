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
      case 'onOverlayDetected':
        return OverlayDetected(
          fullyObscured: map['fullyObscured'] as bool? ?? false,
          partiallyObscured: map['partiallyObscured'] as bool? ?? false,
        );
      case 'onOverlayCleared':
        return const OverlayCleared();
      case 'onSuspiciousTouchDetected':
        return SuspiciousTouchDetected(
          riskScore: map['riskScore'] as int? ?? 0,
          reasons: (map['reasons'] as List?)?.cast<String>() ?? const <String>[],
        );
      case 'onTouchGuardCleared':
        return const TouchGuardCleared();
      case 'onThirdPartyKeyboardDetected':
        return ThirdPartyKeyboardDetected(
          inputMethodId: map['inputMethodId'] as String? ?? '',
          packageName: map['packageName'] as String? ?? '',
          label: map['label'] as String? ?? '',
        );
      case 'onSuspiciousAccessibilityServiceDetected':
        return SuspiciousAccessibilityServiceDetected(
          packageNames: (map['packageNames'] as List?)?.cast<String>() ?? const <String>[],
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

/// A protected screen (see [CShieldAntiOverlay]) received a touch while another
/// window was drawn on top of it — the signature of an overlay/tapjacking attempt.
class OverlayDetected extends CShieldEvent {
  /// Another window completely covers the touched view (strongest signal).
  final bool fullyObscured;

  /// Another window covers part of the screen (API 29+; weaker signal).
  final bool partiallyObscured;

  const OverlayDetected({required this.fullyObscured, required this.partiallyObscured});
}

/// A previously obscured protected screen is clear again.
class OverlayCleared extends CShieldEvent {
  const OverlayCleared();
}

/// A protected screen (see [CShieldBehavioralTouchGuard]) received input that
/// looks machine-generated (auto-clicker, ADB `input tap`, injected event).
class SuspiciousTouchDetected extends CShieldEvent {
  /// Confidence that the input is synthetic, 0..100.
  final int riskScore;

  /// The signals that made up [riskScore] (native `TouchGuardReason` names).
  final List<String> reasons;

  const SuspiciousTouchDetected({required this.riskScore, required this.reasons});
}

/// Input on a protected screen looks human again after a prior
/// [SuspiciousTouchDetected].
class TouchGuardCleared extends CShieldEvent {
  const TouchGuardCleared();
}
/// The device's active keyboard (IME) is neither a system keyboard nor on the
/// trusted allowlist — a third-party IME can read everything the user types.
///
/// Named *Detected*, not *Blocked* (cf. iOS, which can refuse a keyboard
/// extension): Android cannot block the system keyboard the user chose, so the
/// guard only reports. See [CShieldAntiKeylogger].
class ThirdPartyKeyboardDetected extends CShieldEvent {
  /// Raw IME component id (`pkg/.ServiceName`).
  final String inputMethodId;

  /// The IME's package.
  final String packageName;

  /// The IME's display label, or [packageName] if it could not be resolved.
  final String label;

  const ThirdPartyKeyboardDetected({
    required this.inputMethodId,
    required this.packageName,
    required this.label,
  });
}

/// One or more enabled accessibility services belong to apps other than the
/// host and are not on the trusted allowlist — such a service can read typed
/// text (a keylogger vector). Android-only; iOS never emits this.
class SuspiciousAccessibilityServiceDetected extends CShieldEvent {
  /// Packages owning at least one enabled, untrusted accessibility service.
  final List<String> packageNames;

  const SuspiciousAccessibilityServiceDetected({required this.packageNames});
}
