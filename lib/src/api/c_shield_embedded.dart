import '../internal/platform/c_shield_embedded_platform_interface.dart';
import 'event/c_shield_event.dart';

class CShieldEmbedded {
  CShieldEmbedded._();

  /// Loads the native library and starts the SDK. Call once, as early as
  /// possible in `main()`.
  ///
  /// Device attestation starts in the background as soon as this returns; it
  /// does not block the call.
  ///
  /// [cloudProjectNumber] is the Google Cloud project number used for Play
  /// Integrity, as a **string of digits** (for example `"970898117522"`). It is
  /// a string to avoid 64-bit integer pitfalls across the method channel.
  /// **Android only**: iOS ignores it, because App Attest does not need it.
  ///
  /// Passing `null`, or omitting it, deliberately **disables Play Integrity**.
  /// Android then runs Key Attestation only, skips the Play Integrity warm-up,
  /// and does not send `cloud_project_number` to the backend. Requests are
  /// still signed as usual, but trust cannot be raised: calling
  /// `CShieldAttest.ensureTrust` (directly, or through an interceptor's
  /// `requiredLevel`) throws a [CShieldException] with code
  /// [CShieldErrorCode.playIntegrityNotConfigured].
  ///
  /// A non-empty value that is not a positive integer makes the native side
  /// throw, so a typo fails fast.
  ///
  /// The environment and backend URL are not passed here. The native SDK takes
  /// them from its injected parameters, or from the defaults of the AAR
  /// variant.
  static Future<void> initialize({
    required String license,
    String? cloudProjectNumber,
  }) async {
    await CShieldEmbeddedPlatform.instance
        .initialize(license: license, cloudProjectNumber: cloudProjectNumber);
  }

  /// Broadcast stream of every native SDK event: license lifecycle,
  /// attestation state changes, and the overlay, touch-guard and keylogger
  /// detections. See [CShieldEvent] for the event types.
  ///
  /// Subscribe after [initialize]; before that the native side is not wired
  /// up and no events are delivered.
  static Stream<CShieldEvent> get events => CShieldEmbeddedPlatform.instance.events;
}
