package com.cmc.c_shield_embedded.c_shield_embedded

/**
 * Error codes sent to Dart as the `code` of a method-channel error. Must match
 * `CShieldErrorCode.platformCode` in Dart and CShieldErrorCode.swift (iOS) — keep them in sync.
 */
internal object CShieldErrorCode {
    const val AIP_INVALID_SIGNATURE = "aip_invalid_signature"
    const val AIP_SIGNING_FAILED    = "aip_signing_failed"
    const val SSL_NOT_CONFIGURED    = "ssl_not_configured"
    const val SSL_PIN_MISMATCH      = "ssl_pin_mismatch"
    const val INVALID_ARGUMENT      = "invalid_argument"
    const val NATIVE_ERROR          = "native_error"
    const val NOT_READY             = "not_ready"
    // ensureTrust was called although initialize got NO cloudProjectNumber (Play Integrity off).
    // Matches CShieldPlayIntegrityDisabledException.REASON in the native SDK.
    const val PLAY_INTEGRITY_NOT_CONFIGURED = "play_integrity_not_configured"
    // Emitted by iOS only (malware.* does not exist there). Declared here so both platforms keep
    // the same code table.
    const val UNSUPPORTED_PLATFORM = "unsupported_platform"
}
