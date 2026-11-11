import Foundation

/// Mirrors CShieldErrorCode.kt (android) — keep both in sync.
enum CShieldErrorCode {
    static let aipInvalidSignature = "aip_invalid_signature"
    static let aipSigningFailed    = "aip_signing_failed"
    static let sslNotConfigured    = "ssl_not_configured"
    static let sslPinMismatch      = "ssl_pin_mismatch"
    static let invalidArgument     = "invalid_argument"
    static let nativeError         = "native_error"
    static let notReady            = "not_ready"
    /// Tính năng chỉ có trên Android (vd `malware.*`) — iOS trả mã này thay vì notImplemented âm thầm.
    static let unsupportedPlatform = "unsupported_platform"
}
