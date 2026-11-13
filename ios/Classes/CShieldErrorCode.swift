import Foundation

/// Error codes sent to Dart as the `code` of a `FlutterError`. Must match
/// `CShieldErrorCode.platformCode` in Dart.
///
/// Mirrors CShieldErrorCode.kt (android) — keep both in sync.
enum CShieldErrorCode {
    static let aipInvalidSignature = "aip_invalid_signature"
    static let aipSigningFailed    = "aip_signing_failed"
    static let sslNotConfigured    = "ssl_not_configured"
    static let sslPinMismatch      = "ssl_pin_mismatch"
    static let invalidArgument     = "invalid_argument"
    static let nativeError         = "native_error"
    static let notReady            = "not_ready"
    /// The feature exists on Android only (for example `malware.*`). iOS returns this code
    /// instead of a bare notImplemented.
    static let unsupportedPlatform = "unsupported_platform"
}
