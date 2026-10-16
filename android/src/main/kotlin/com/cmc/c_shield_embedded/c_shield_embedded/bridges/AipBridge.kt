package com.cmc.c_shield_embedded.c_shield_embedded.bridges

import android.content.Context
import android.os.Handler
import android.os.Looper
import com.cmc.c_shield_embedded.c_shield_embedded.CShieldErrorCode
import com.cmc.cshield_embedded.aip.api.AIPCore
import com.cmc.cshield_embedded.aip.signing.HardwareRequestSigner
import com.cmc.cshield_embedded.aip.signing.RequestContext
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import kotlin.collections.mutableMapOf

class AipBridge(private val context: Context) {

    private val mainHandler = Handler(Looper.getMainLooper())

    // Ký bằng hardware key (fallback baked-key đã bỏ). Stateless → chia sẻ một instance.
    private val requestSigner = HardwareRequestSigner()

    // Only the cryptographic sign/verify are exposed to Flutter. Body
    // normalization, payload construction, hashing and the response
    // timestamp-window check are all done in Dart (AIPNormalizer / CShieldAIP),
    // so no fabricated okhttp Request/URL is needed here.
    fun handle(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "aip.verify" -> handleVerify(call, result)
            "aip.signRequest" -> handleSignRequest(call, result)
            else -> result.notImplemented()
        }
    }

    private fun handleVerify(call: MethodCall, result: MethodChannel.Result) {
        val payload = call.argument<String>("payload")
            ?: return result.error(CShieldErrorCode.INVALID_ARGUMENT, "payload required", null)
        val signature = call.argument<String>("signature")
            ?: return result.error(CShieldErrorCode.INVALID_ARGUMENT, "signature required", null)

        Thread {
            try {
                val valid = AIPCore.verifySign(context, payload, signature)
                mainHandler.post {
                    if (valid) result.success(null)
                    else result.error(CShieldErrorCode.AIP_INVALID_SIGNATURE, "Signature verification failed", null)
                }
            } catch (e: Throwable) {
                mainHandler.post { result.error(CShieldErrorCode.NATIVE_ERROR, e.message, null) }
            }
        }.start()
    }

    private fun handleSignRequest(call: MethodCall, result: MethodChannel.Result) {
        val method = call.argument<String>("method")
            ?: return result.error(CShieldErrorCode.INVALID_ARGUMENT, "method required", null)
        val path = call.argument<String>("path")
            ?: return result.error(CShieldErrorCode.INVALID_ARGUMENT, "path required", null)
        val canonicalQuery = call.argument<String>("canonicalQuery")
            ?: return result.error(CShieldErrorCode.INVALID_ARGUMENT, "canonicalQuery required", null)
        val timestampSec = call.argument<Int>("timestampSec")
            ?: return result.error(CShieldErrorCode.INVALID_ARGUMENT, "timestampSec required", null)
        val bodyHashHex = call.argument<String>("bodyHashHex")
            ?: return result.error(CShieldErrorCode.INVALID_ARGUMENT, "bodyHashHex required", null)

        Thread {
            try {
                val ctx = RequestContext(
                    method = method,
                    path = path,
                    canonicalQuery = canonicalQuery,
                    timestampSec = timestampSec.toLong(),
                    bodyHashHex = bodyHashHex,
                )
                val signature = requestSigner.sign(ctx)
                mainHandler.post { result.success(signature.fold(mutableMapOf<String, String>()) { m, it -> m.apply { put(it.name, it.value) } }) }
            } catch (e: Throwable) {
                mainHandler.post { result.error(CShieldErrorCode.AIP_SIGNING_FAILED, e.message, null) }
            }
        }.start()
    }

}
