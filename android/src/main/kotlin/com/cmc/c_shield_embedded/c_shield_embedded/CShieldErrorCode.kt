package com.cmc.c_shield_embedded.c_shield_embedded

internal object CShieldErrorCode {
    const val AIP_INVALID_SIGNATURE = "aip_invalid_signature"
    const val AIP_SIGNING_FAILED    = "aip_signing_failed"
    const val SSL_NOT_CONFIGURED    = "ssl_not_configured"
    const val SSL_PIN_MISMATCH      = "ssl_pin_mismatch"
    const val INVALID_ARGUMENT      = "invalid_argument"
    const val NATIVE_ERROR          = "native_error"
    const val NOT_READY             = "not_ready"
}
