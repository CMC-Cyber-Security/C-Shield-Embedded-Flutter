package com.cmc.c_shield_embedded.c_shield_embedded.bridges

import android.app.Activity
import com.cmc.c_shield_embedded.c_shield_embedded.CShieldErrorCode
import com.cmc.cshield_embedded.btg.api.CShieldBehavioralTouchGuard
import com.cmc.cshield_embedded.btg.api.TouchGuardConfig
import com.cmc.cshield_embedded.btg.api.TouchGuardEvent
import com.cmc.cshield_embedded.btg.api.TouchGuardListener
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Adapts the native Behavioral Touch Guard (com.cmc.cshield_embedded.btg) to the
 * Flutter plugin.
 *
 * protect() hardens the host's current Activity window and analyses every touch
 * for machine-generated input (auto-clicker, ADB `input tap`, injected events);
 * the native [TouchGuardListener] callbacks are forwarded to Dart over the shared
 * event channel (same sink as license/overlay events) as `onSuspiciousTouchDetected`
 * / `onTouchGuardCleared`.
 *
 * Android-only: wraps the Activity's Window.Callback to read `MotionEvent`s —
 * there is no iOS counterpart.
 */
class BehavioralTouchGuardBridge(
    private val activityProvider: () -> Activity?,
    private val eventSink: () -> EventChannel.EventSink?,
) {
    private fun protect(call: MethodCall, result: MethodChannel.Result) {
        val activity = activityProvider()
            ?: return result.error(CShieldErrorCode.NATIVE_ERROR, "No active Activity to protect", null)
        val config = TouchGuardConfig(
            riskThreshold = call.argument<Int>("riskThreshold") ?: TouchGuardConfig().riskThreshold,
            blockWhenDetected = call.argument<Boolean>("blockWhenDetected") ?: false,
            includeAccessibilitySignal = call.argument<Boolean>("includeAccessibilitySignal") ?: false,
        )
        try {
            CShieldBehavioralTouchGuard.protect(
                activity,
                config,
                object : TouchGuardListener {
                    override fun onSuspiciousTouchDetected(event: TouchGuardEvent) {
                        eventSink()?.success(
                            mapOf(
                                "event" to "onSuspiciousTouchDetected",
                                "riskScore" to event.riskScore,
                                "reasons" to event.reasons.map { it.name },
                            )
                        )
                    }

                    override fun onCleared() {
                        eventSink()?.success(mapOf("event" to "onTouchGuardCleared"))
                    }
                },
            )
            result.success(null)
        } catch (e: Throwable) {
            result.error(CShieldErrorCode.NATIVE_ERROR, e.message, null)
        }
    }

    private fun unprotect(result: MethodChannel.Result) {
        val activity = activityProvider() ?: return result.success(null)
        CShieldBehavioralTouchGuard.unprotect(activity)
        result.success(null)
    }

    fun handle(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "btg.protect" -> protect(call, result)
            "btg.unprotect" -> unprotect(result)
            else -> result.notImplemented()
        }
    }
}
