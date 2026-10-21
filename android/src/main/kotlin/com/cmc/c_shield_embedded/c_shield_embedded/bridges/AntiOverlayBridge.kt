package com.cmc.c_shield_embedded.c_shield_embedded.bridges

import android.app.Activity
import com.cmc.c_shield_embedded.c_shield_embedded.CShieldErrorCode
import com.cmc.cshield_embedded.antioverlay.api.CShieldAntiOverlay
import com.cmc.cshield_embedded.antioverlay.api.OverlayEvent
import com.cmc.cshield_embedded.antioverlay.api.OverlayGuardConfig
import com.cmc.cshield_embedded.antioverlay.api.OverlayListener
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Adapts the native runtime anti-overlay/anti-tapjacking guard
 * (com.cmc.cshield_embedded.antioverlay) to the Flutter plugin.
 *
 * protect() hardens the host's current Activity window; the native
 * [OverlayListener] callbacks are forwarded to Dart over the shared event
 * channel (same sink as license events) as `onOverlayDetected` / `onOverlayCleared`.
 *
 * Android-only: wraps the Activity's Window.Callback to read Android's
 * "window is obscured" touch flags — there is no iOS counterpart.
 */
class AntiOverlayBridge(
    private val activityProvider: () -> Activity?,
    private val eventSink: () -> EventChannel.EventSink?,
) {
    private fun protect(call: MethodCall, result: MethodChannel.Result) {
        val activity = activityProvider()
            ?: return result.error(CShieldErrorCode.NATIVE_ERROR, "No active Activity to protect", null)
        val blockObscuredTouches = call.argument<Boolean>("blockObscuredTouches") ?: true
        try {
            CShieldAntiOverlay.protect(
                activity,
                OverlayGuardConfig(blockObscuredTouches = blockObscuredTouches),
                object : OverlayListener {
                    override fun onOverlayDetected(event: OverlayEvent) {
                        eventSink()?.success(
                            mapOf(
                                "event" to "onOverlayDetected",
                                "fullyObscured" to event.fullyObscured,
                                "partiallyObscured" to event.partiallyObscured,
                            )
                        )
                    }

                    override fun onCleared() {
                        eventSink()?.success(mapOf("event" to "onOverlayCleared"))
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
        CShieldAntiOverlay.unprotect(activity)
        result.success(null)
    }

    fun handle(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "antiOverlay.protect" -> protect(call, result)
            "antiOverlay.unprotect" -> unprotect(result)
            else -> result.notImplemented()
        }
    }
}
