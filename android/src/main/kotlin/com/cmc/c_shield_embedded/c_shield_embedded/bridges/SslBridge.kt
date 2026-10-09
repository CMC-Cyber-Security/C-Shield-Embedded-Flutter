package com.cmc.c_shield_embedded.c_shield_embedded.bridges

import android.os.Handler
import android.os.Looper
import android.util.Base64
import com.cmc.c_shield_embedded.c_shield_embedded.CShieldErrorCode
import com.cmc.cshield_embedded.aip.pinning.CShieldSSL
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody
import okhttp3.RequestBody.Companion.toRequestBody
import java.io.ByteArrayInputStream
import java.security.cert.CertificateException
import java.security.cert.CertificateFactory
import java.security.cert.X509Certificate
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import kotlin.collections.component1
import kotlin.collections.component2

class SslBridge {

    // Network I/O must not run on the platform (main) thread; results are posted
    // back to the main thread because MethodChannel.Result must be invoked there.
    private val executor = Executors.newCachedThreadPool()
    private val mainHandler = Handler(Looper.getMainLooper())

    fun handle(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "ssl.configure"          -> handleConfigure(call, result)
            "ssl.updatePins"         -> handleUpdatePins(call, result)
            "ssl.isConfigured"       -> result.success(CShieldSSL.isConfigured())
            "ssl.checkServerTrusted" -> handleCheckServerTrusted(call, result)
            "ssl.httpRequest"        -> handleHttpRequest(call, result)
            else -> result.notImplemented()
        }
    }

    private fun handleConfigure(call: MethodCall, result: MethodChannel.Result) {
        val pins = call.argument<List<String>>("pins")
            ?: return result.error(CShieldErrorCode.INVALID_ARGUMENT, "pins required", null)
        val hostname = call.argument<String>("hostname")
            ?: return result.error(CShieldErrorCode.INVALID_ARGUMENT, "hostname required", null)
        try {
            CShieldSSL.configure(pins = pins, hostname = hostname)
            result.success(null)
        } catch (e: Throwable) {
            result.error(CShieldErrorCode.NATIVE_ERROR, e.message, null)
        }
    }

    private fun handleUpdatePins(call: MethodCall, result: MethodChannel.Result) {
        val pins = call.argument<List<String>>("pins")
            ?: return result.error(CShieldErrorCode.INVALID_ARGUMENT, "pins required", null)
        val hostname = call.argument<String>("hostname")
            ?: return result.error(CShieldErrorCode.INVALID_ARGUMENT, "hostname required", null)
        try {
            CShieldSSL.updatePins(pins = pins, hostname = hostname)
            result.success(null)
        } catch (e: IllegalStateException) {
            result.error(CShieldErrorCode.SSL_NOT_CONFIGURED, e.message, null)
        } catch (e: Throwable) {
            result.error(CShieldErrorCode.NATIVE_ERROR, e.message, null)
        }
    }

    /**
     * Verifies a DER-encoded certificate (base64) using [CShieldSSL.getTrustManager],
     * which performs system CA validation + SPKI pin check.
     *
     * Flutter equivalent of CShieldTrustManager.checkServerTrusted() on Android.
     */
    private fun handleCheckServerTrusted(call: MethodCall, result: MethodChannel.Result) {
        val certDerBase64 = call.argument<String>("certDer")
            ?: return result.error(CShieldErrorCode.INVALID_ARGUMENT, "certDer required", null)
        val host = call.argument<String>("host") ?: ""

        if (!CShieldSSL.isConfigured()) {
            return result.error(CShieldErrorCode.SSL_NOT_CONFIGURED, "CShieldSSL not configured", null)
        }

        try {
            val certBytes = Base64.decode(certDerBase64, Base64.DEFAULT)
            val factory = CertificateFactory.getInstance("X.509")
            val cert = factory.generateCertificate(ByteArrayInputStream(certBytes)) as X509Certificate

            // CShieldTrustManager.checkServerTrusted performs:
            //   1. System CA validation via X509TrustManagerExtensions (blocks user-installed CAs)
            //   2. SPKI pin verification against configured pins
            CShieldSSL.getTrustManager().checkServerTrusted(arrayOf(cert), "RSA")
            result.success(true)
        } catch (e: CertificateException) {
            result.success(false)
        } catch (e: Throwable) {
            result.error(CShieldErrorCode.NATIVE_ERROR, e.message, null)
        }
    }

    /**
     * Performs an HTTPS request through OkHttp configured with
     * [CShieldSSL.getSSLSocketFactory] + [CShieldSSL.getTrustManager], so
     * certificate pinning runs at the TLS layer over the FULL chain.
     *
     * Flutter's Dart adapter (CShieldNativeHttpAdapter) delegates the pinned
     * host's requests here; this is what lets Flutter match intermediate/root
     * pins that pure-Dart networking cannot.
     */
    private fun handleHttpRequest(call: MethodCall, result: MethodChannel.Result) {
        val method = (call.argument<String>("method") ?: "GET").uppercase()
        val url = call.argument<String>("url")
            ?: return result.error(CShieldErrorCode.INVALID_ARGUMENT, "url required", null)
        val headers = call.argument<Map<String, String>>("headers") ?: emptyMap()
        val body = call.argument<ByteArray>("body")
        val connectTimeoutMs = call.argument<Int>("connectTimeoutMs")
        val receiveTimeoutMs = call.argument<Int>("receiveTimeoutMs")
        val followRedirects = call.argument<Boolean>("followRedirects") ?: true

        if (!CShieldSSL.isConfigured()) {
            return result.error(CShieldErrorCode.SSL_NOT_CONFIGURED, "CShieldSSL not configured", null)
        }

        executor.execute {
            try {
                val builder = OkHttpClient.Builder()
                    .sslSocketFactory(CShieldSSL.getSSLSocketFactory(), CShieldSSL.getTrustManager())
                    .followRedirects(followRedirects)
                    .followSslRedirects(followRedirects)
                    // FIX B — re-verify SPKI pin Ở NATIVE (độc lập CShieldTrustManager Java).
                    // Chạy sau handshake, TRƯỚC khi gửi request: nếu attacker hook/thay
                    // TrustManager Java để bỏ pin thì bước native này vẫn chặn MITM.
                    // Native fail-open khi chưa sẵn sàng (trả true) nên không ảnh hưởng bình thường.
                    .addNetworkInterceptor { chain ->
                        val h = chain.request().url.host
                        val ders = (chain.connection()?.handshake()?.peerCertificates ?: emptyList())
                            .filterIsInstance<X509Certificate>()
                            .map { it.encoded }
                            .toTypedArray()
                        if (!CShieldSSL.verifyChainNative(h, ders)) {
                            throw javax.net.ssl.SSLPeerUnverifiedException(
                                "CShield native pin mismatch for $h"
                            )
                        }
                        chain.proceed(chain.request())
                    }
                connectTimeoutMs?.let { if (it > 0) builder.connectTimeout(it.toLong(), TimeUnit.MILLISECONDS) }
                receiveTimeoutMs?.let { if (it > 0) builder.readTimeout(it.toLong(), TimeUnit.MILLISECONDS) }
                val client = builder.build()

                // OkHttp requires a body for POST/PUT/PATCH etc. and forbids one
                // for GET/HEAD. Content-Type is carried via the headers map below.
                val requestBody: RequestBody? = when {
                    body != null -> body.toRequestBody(null)
                    requiresRequestBody(method) -> ByteArray(0).toRequestBody(null)
                    else -> null
                }

                val reqBuilder = Request.Builder().url(url).method(method, requestBody)
                headers.forEach { (k, v) -> reqBuilder.header(k, v) }

                client.newCall(reqBuilder.build()).execute().use { response ->
                    val bodyBytes = response.body?.bytes() ?: ByteArray(0)
                    val headerMap = HashMap<String, List<String>>()
                    response.headers.names().forEach { name ->
                        headerMap[name] = response.headers.values(name)
                    }
                    val payload = hashMapOf<String, Any?>(
                        "statusCode" to response.code,
                        "reasonPhrase" to response.message,
                        "headers" to headerMap,
                        "body" to bodyBytes,
                    )
                    mainHandler.post { result.success(payload) }
                }
            } catch (e: javax.net.ssl.SSLPeerUnverifiedException) {
                mainHandler.post {
                    result.error(CShieldErrorCode.SSL_PIN_MISMATCH, e.message ?: "Certificate pin mismatch", null)
                }
            } catch (e: javax.net.ssl.SSLHandshakeException) {
                // CShieldTrustManager rejects the chain (pin mismatch or untrusted CA)
                // by throwing CertificateException during the handshake; OkHttp
                // surfaces it wrapped in SSLHandshakeException.
                val certFailure = generateSequence<Throwable>(e) { it.cause }
                    .firstOrNull { it is CertificateException }
                mainHandler.post {
                    if (certFailure != null) {
                        result.error(CShieldErrorCode.SSL_PIN_MISMATCH, certFailure.message ?: "Certificate pin mismatch", null)
                    } else {
                        result.error(CShieldErrorCode.NATIVE_ERROR, e.message, null)
                    }
                }
            } catch (e: Throwable) {
                mainHandler.post { result.error(CShieldErrorCode.NATIVE_ERROR, e.message, null) }
            }
        }
    }

    private fun requiresRequestBody(method: String): Boolean =
        method in setOf("POST", "PUT", "PATCH", "PROPPATCH", "REPORT")
}