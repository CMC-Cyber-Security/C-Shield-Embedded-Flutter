package com.cmc.c_shield_embedded.c_shield_embedded.bridges

import android.os.Handler
import android.os.Looper
import com.cmc.c_shield_embedded.c_shield_embedded.CShieldErrorCode
import com.cmc.cshield_embedded.CShieldSDK
import com.cmc.cshield_embedded.CShieldState
import com.cmc.cshield_embedded.TrustLevel
import com.cmc.cshield_embedded.common.CShieldPlayIntegrityDisabledException
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Attestation bridge to Dart. Exposes the [CShieldSDK] contract as is: readiness
 * ([CShieldState]), trust ([TrustLevel]), and on-demand trust elevation (`ensureTrust`).
 *
 * The BLOCKING calls (`awaitReady` / `ensureTrust`, which wait for registration, refresh or Play
 * Integrity) run on a background thread and post their result back to the main thread, so they
 * NEVER block Flutter's main thread. The READ calls (`state` / `lastError` /
 * `currentTrustLevel`) do not block and answer directly.
 *
 * Enums cross the method channel as NAMES (`"READY"`, `"L4"`, `"SATISFIED"`); Dart maps them back.
 *
 * Mirrored by AttestBridge.swift (iOS) — keep both in sync.
 */
class AttestBridge {

    private val mainHandler = Handler(Looper.getMainLooper())

    fun handle(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "attest.state" -> result.success(CShieldSDK.state().name)
            "attest.lastError" -> result.success(CShieldSDK.lastError())
            "attest.currentTrustLevel" -> result.success(CShieldSDK.currentTrustLevel().name)
            "attest.awaitReady" -> handleAwaitReady(call, result)
            "attest.ensureTrust" -> handleEnsureTrust(call, result)
            else -> result.notImplemented()
        }
    }

    /** Waits until ready (or until the timeout) and returns the name of the final [CShieldState]. */
    private fun handleAwaitReady(call: MethodCall, result: MethodChannel.Result) {
        val timeoutMs = (call.argument<Int>("timeoutMs") ?: 8_000).toLong()
        onBackground(result) { CShieldSDK.awaitReady(timeoutMs).name }
    }

    /**
     * Raises trust to at least `minLevel` before a sensitive flow (spends Play Integrity quota
     * when trust has to be raised, or when `requireFresh` is set).
     * A missing or unmappable `minLevel` → [CShieldErrorCode.INVALID_ARGUMENT], rather than
     * silently raising to the wrong level.
     */
    private fun handleEnsureTrust(call: MethodCall, result: MethodChannel.Result) {
        val minLevelId = call.argument<String>("minLevel")
            ?: return result.error(CShieldErrorCode.INVALID_ARGUMENT, "minLevel required", null)
        val minLevel = TrustLevel.fromId(minLevelId)
        if (minLevel == TrustLevel.UNKNOWN) {
            return result.error(CShieldErrorCode.INVALID_ARGUMENT, "minLevel invalid: $minLevelId", null)
        }
        val requireFresh = call.argument<Boolean>("requireFresh") ?: false
        val timeoutMs = (call.argument<Int>("timeoutMs") ?: 15_000).toLong()

        onBackground(result) { CShieldSDK.ensureTrust(minLevel, requireFresh, timeoutMs).name }
    }

    /** Runs a blocking SDK call on a background thread and posts its outcome to the main thread. */
    private fun onBackground(result: MethodChannel.Result, block: () -> Any?) {
        Thread {
            try {
                val value = block()
                mainHandler.post { result.success(value) }
            } catch (e: CShieldPlayIntegrityDisabledException) {
                // ensureTrust was called with Play Integrity off (no cloudProjectNumber) →
                // a dedicated code for Dart.
                mainHandler.post { result.error(CShieldErrorCode.PLAY_INTEGRITY_NOT_CONFIGURED, e.message, null) }
            } catch (e: Throwable) {
                mainHandler.post { result.error(CShieldErrorCode.NATIVE_ERROR, e.message, null) }
            }
        }.start()
    }
}
