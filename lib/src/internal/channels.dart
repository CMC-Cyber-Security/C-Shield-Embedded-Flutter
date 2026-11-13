/// Names of the method/event channels and of the methods invoked on them.
/// Must match the native plugins (Kotlin and Swift).
class CShieldChannels {
  static const String methodChannel = 'c_shield_embedded';

  // Streams native SDK events to Dart: license lifecycle (onLicenseRenewed /
  // onLicenseRevoked), attestation state (onAttestStateChanged), and the
  // overlay / touch-guard / keylogger detections.
  static const String eventChannel = 'c_shield_embedded_event';

  static const String sdkInitialize = 'sdk.initialize';

  static const String sslConfigure = 'ssl.configure';
  static const String sslUpdatePins = 'ssl.updatePins';
  static const String sslIsConfigured = 'ssl.isConfigured';
  static const String sslCheckServerTrusted = 'ssl.checkServerTrusted';

  // Performs an HTTPS request entirely on the native side (OkHttp on Android,
  // URLSession on iOS) so that certificate pinning runs at the native TLS layer
  // with the FULL certificate chain — enabling intermediate/root pin matching
  // that pure-Dart networking cannot do (dart:io only exposes the leaf cert).
  static const String sslHttpRequest = 'ssl.httpRequest';

  // AIP — only the cryptographic sign/verify cross to native. Body
  // normalization, payload construction and the timestamp-window check are
  // done in Dart (CShieldAIP / AIPNormalizer).
  static const String aipVerify = 'aip.verify';
  static const String aipSignRequest = 'aip.signRequest';
  // Forces an access-token refresh after a 401 invalid token. Returns a bool:
  // whether a new token is ready.
  static const String aipForceRefresh = 'aip.forceRefresh';

  // Attestation — readiness (state/lastError/awaitReady) + trust
  // (currentTrustLevel/ensureTrust). Enums cross the channel as NAMES ("READY",
  // "L4", "SATISFIED"); Dart maps them back to enums. ensureTrust/awaitReady
  // BLOCK on the native side, which therefore runs them on a background thread.
  static const String attestState = 'attest.state';
  static const String attestLastError = 'attest.lastError';
  static const String attestAwaitReady = 'attest.awaitReady';
  static const String attestCurrentTrustLevel = 'attest.currentTrustLevel';
  static const String attestEnsureTrust = 'attest.ensureTrust';

  // Anti-malware scanning. Android-only.
  static const String malwareScanDevice = 'malware.scanDevice';
  static const String malwareAnalyzeApkFile = 'malware.analyzeApkFile';
  static const String malwareAnalyzeInstalledApp = 'malware.analyzeInstalledApp';
  static const String malwareStopScan = 'malware.cancelScanning';

  // Anti-overlay / anti-tapjacking runtime guard. protect() hardens the host's
  // current Activity window; obscured-screen callbacks arrive over [eventChannel]
  // as OverlayDetected / OverlayCleared events. Android-only.
  static const String antiOverlayProtect = 'antiOverlay.protect';
  static const String antiOverlayUnprotect = 'antiOverlay.unprotect';

  // Behavioral Touch Guard — runtime detection of machine-generated input
  // (auto-clicker, `adb shell input tap`, injected events). protect() hardens
  // the host's current Activity window; suspicious-touch callbacks arrive over
  // [eventChannel] as SuspiciousTouchDetected / TouchGuardCleared. Android-only.
  static const String btgProtect = 'btg.protect';
  static const String btgUnprotect = 'btg.unprotect';

  // Anti-keylogger runtime guard. Auto-started inside [sdkInitialize]; detections
  // (untrusted keyboard / accessibility service) arrive over [eventChannel] as
  // onThirdPartyKeyboardDetected / onSuspiciousAccessibilityServiceDetected.
  // configure() sets the trust allowlists; runCheck() re-evaluates on demand.
  // The keyboard event is emitted on both platforms; the accessibility event
  // and configure()/runCheck() are Android-only (no-ops on iOS).
  static const String antiKeyloggerConfigure = 'antiKeylogger.configure';
  static const String antiKeyloggerRunCheck = 'antiKeylogger.runCheck';
}
