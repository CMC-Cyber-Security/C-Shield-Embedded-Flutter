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
