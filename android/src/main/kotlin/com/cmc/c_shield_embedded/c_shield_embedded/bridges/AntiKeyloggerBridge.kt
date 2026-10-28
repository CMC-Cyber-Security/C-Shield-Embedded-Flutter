package com.cmc.c_shield_embedded.c_shield_embedded.bridges

import com.cmc.c_shield_embedded.c_shield_embedded.CShieldErrorCode
import com.cmc.cshield_embedded.antikeylogger.api.AntiKeyloggerConfig
import com.cmc.cshield_embedded.antikeylogger.api.AntiKeyloggerEvent
import com.cmc.cshield_embedded.antikeylogger.api.CShieldAntiKeylogger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Adapts the native anti-keylogger guard (com.cmc.cshield_embedded.antikeylogger)
 * to the Flutter plugin.
 *
 * The guard is auto-started by `CShieldSDK.initialize`; this bridge wires its
 * global `onDetection` callback to the shared event channel (same sink as license
 * / overlay events) as `onThirdPartyKeyboardDetected` /
 * `onSuspiciousAccessibilityServiceDetected`, and exposes configure() / runCheck().
 *
 * Android-only: reads the active IME + enabled accessibility services.
 */
class AntiKeyloggerBridge(
    private val eventSink: () -> EventChannel.EventSink?,
) {
    // Native detections → Dart event channel. Always re-passed to
    // [CShieldAntiKeylogger.configure] so changing the allowlist never drops event routing.
    private val detectionListener: (AntiKeyloggerEvent) -> Unit = { event ->
        when (event) {
            is AntiKeyloggerEvent.ThirdPartyKeyboardDetected ->
                eventSink()?.success(
                    mapOf(
                        "event" to "onThirdPartyKeyboardDetected",
                        "inputMethodId" to event.inputMethodId,
                        "packageName" to event.packageName,
                        "label" to event.label,
                    )
                )
            is AntiKeyloggerEvent.SuspiciousAccessibilityServiceDetected ->
                eventSink()?.success(
                    mapOf(
                        "event" to "onSuspiciousAccessibilityServiceDetected",
                        "packageNames" to event.packageNames.toList(),
                    )
                )
        }
    }

    /** Wires the detection callback with default config. Call once (before/at SDK init). */
    fun wireDetection() {
        CShieldAntiKeylogger.configure(AntiKeyloggerConfig(), detectionListener)
    }

    private fun configure(call: MethodCall, result: MethodChannel.Result) {
        try {
            val trustSystemKeyboards = call.argument<Boolean>("trustSystemKeyboards") ?: true
            val keyboards = call.argument<List<String>>("trustedKeyboardPackages").orEmpty()
            val accessibility = call.argument<List<String>>("trustedAccessibilityPackages").orEmpty()
            val config = AntiKeyloggerConfig(
                trustSystemKeyboards = trustSystemKeyboards,
                // Empty keyboard allowlist keeps the native default (Gboard / Samsung / SwiftKey).
                trustedKeyboardPackages = if (keyboards.isEmpty()) {
                    AntiKeyloggerConfig.DEFAULT_TRUSTED_KEYBOARDS
                } else {
                    keyboards.toSet()
                },
                trustedAccessibilityPackages = accessibility.toSet(),
            )
            // Re-pass the listener so the detection routing survives the config change.
            CShieldAntiKeylogger.configure(config, detectionListener)
            result.success(null)
        } catch (e: Throwable) {
            result.error(CShieldErrorCode.NATIVE_ERROR, e.message, null)
        }
    }

    fun handle(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "antiKeylogger.configure" -> configure(call, result)
            "antiKeylogger.runCheck" -> {
                CShieldAntiKeylogger.runCheck()
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }
}
