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
      default:
        throw ArgumentError('Unknown event: $event');
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
