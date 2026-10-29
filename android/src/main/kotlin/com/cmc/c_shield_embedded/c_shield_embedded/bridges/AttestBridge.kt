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
 * Cầu nối attestation v2 sang Dart — phơi nguyên hợp đồng của [CShieldSDK]: readiness
 * ([CShieldState]) + trust ([TrustLevel]) + nâng trust theo yêu cầu (`ensureTrust`).
 *
 * Mọi hàm của SDK ở đây đều BLOCK (chờ register/refresh/Play Integrity) nên chạy trên thread nền
 * rồi post kết quả về main thread — KHÔNG bao giờ block main thread của Flutter.
 *
 * Enum cross method-channel dưới dạng TÊN (`"READY"`, `"L4"`, `"SATISFIED"`); Dart map ngược lại.
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

    /** Chờ tới khi sẵn sàng (hoặc hết timeout) → trả tên [CShieldState] cuối. */
    private fun handleAwaitReady(call: MethodCall, result: MethodChannel.Result) {
        val timeoutMs = (call.argument<Int>("timeoutMs") ?: 8_000).toLong()
        onBackground(result) { CShieldSDK.awaitReady(timeoutMs).name }
    }

    /**
     * Nâng trust ≥ `minLevel` trước luồng nhạy (tốn Play Integrity khi phải nâng / `requireFresh`).
     * `minLevel` sai/không map được → [CShieldErrorCode.INVALID_ARGUMENT] (đừng im lặng nâng nhầm mức).
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

    private fun onBackground(result: MethodChannel.Result, block: () -> Any?) {
        Thread {
            try {
                val value = block()
                mainHandler.post { result.success(value) }
            } catch (e: CShieldPlayIntegrityDisabledException) {
                // ensureTrust gọi khi PI tắt (không truyền cloudProjectNumber) → mã riêng cho Dart.
                mainHandler.post { result.error(CShieldErrorCode.PLAY_INTEGRITY_NOT_CONFIGURED, e.message, null) }
            } catch (e: Throwable) {
                mainHandler.post { result.error(CShieldErrorCode.NATIVE_ERROR, e.message, null) }
            }
        }.start()
    }
}
