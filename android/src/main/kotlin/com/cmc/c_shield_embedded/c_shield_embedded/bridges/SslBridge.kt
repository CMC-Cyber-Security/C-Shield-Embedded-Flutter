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

/**
 * Adapts the native certificate-pinning API ([CShieldSSL]) to the Flutter plugin: pin
 * configuration, single-certificate verification, and pinned HTTPS requests performed natively.
 *
 * Mirrored by SslBridge.swift (iOS) — keep both in sync.
 */
class SslBridge {

    // Network I/O must not run on the platform (main) thread; results are posted
    // back to the main thread because MethodChannel.Result must be invoked there.
    private val executor = Executors.newCachedThreadPool()
    private val mainHandler = Handler(Looper.getMainLooper())

    // Base client that exists only to share its ConnectionPool/Dispatcher; every request builds
    // its own client from it with newBuilder().
    private val baseClient: OkHttpClient by lazy { OkHttpClient() }

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
        // Multi-host: prefer the pinsByHost map (host pattern -> pins). The legacy arguments
        // (pins + hostname) stay supported by wrapping them into a one-entry map.
        val pinsByHost: Map<String, List<String>> = run {
            val map = call.argument<Map<String, List<String>>>("pinsByHost")
            if (map != null && map.isNotEmpty()) return@run map
            val pins = call.argument<List<String>>("pins")
            val hostname = call.argument<String>("hostname")
            if (pins != null && hostname != null) mapOf(hostname to pins) else emptyMap()
        }
        if (pinsByHost.isEmpty()) {
            return result.error(CShieldErrorCode.INVALID_ARGUMENT, "pinsByHost (or pins+hostname) required", null)
        }
        // Sealed by default; the app passes allowRuntimeUpdates = true if it needs to rotate pins
        // at runtime.
        val allowRuntimeUpdates = call.argument<Boolean>("allowRuntimeUpdates") ?: false
        try {
            CShieldSSL.configure(pinsByHost = pinsByHost, allowRuntimeUpdates = allowRuntimeUpdates)
            result.success(null)
        } catch (e: IllegalStateException) {
            // Already sealed (an earlier configure ran in the default sealing mode) → the pin
            // configuration is locked.
            result.error(CShieldErrorCode.SSL_NOT_CONFIGURED, e.message, null)
        } catch (e: IllegalArgumentException) {
            // Malformed host or pin (rejected by PinningConfig) — same code as on iOS
            // (CShieldSSLError.invalidConfiguration).
            result.error(CShieldErrorCode.INVALID_ARGUMENT, e.message, null)
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
            // The pin set is sealed: updatePins only works after
            // configure(allowRuntimeUpdates = true).
            result.error(CShieldErrorCode.SSL_NOT_CONFIGURED, e.message, null)
        } catch (e: IllegalArgumentException) {
            result.error(CShieldErrorCode.INVALID_ARGUMENT, e.message, null)
        } catch (e: Throwable) {
            result.error(CShieldErrorCode.NATIVE_ERROR, e.message, null)
        }
    }

    /**
     * Verifies a single DER-encoded certificate (base64) for `host` with [CShieldSSL.verifyPin].
     *
     * Dart can only pass the leaf certificate, so this is a leaf-only check; see the comment at
     * the call below. A certificate that cannot be parsed yields `false` rather than an error.
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

            // CShieldSSL.verifyPin(host, chain) uses the pins of THIS host (multi-host). With a
            // full chain it also runs system CA validation; with only a leaf (all that dart:io
            // provides) it checks the certificate structure (validity period + hostname) and
            // compares the leaf pin.
            // Do not use getTrustManager().checkServerTrusted(chain, "RSA") here: that overload
            // has no host, so with strict unknown-host handling it always fails, and verifyPin
            // would always return false and report a false MITM through onPinFailure.
            result.success(CShieldSSL.verifyPin(host, listOf(cert)))
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
                // newBuilder() on the base client ⇒ SHARES its ConnectionPool/Dispatcher, which
                // keeps connections alive and reuses TLS sessions across requests (a fresh
                // OkHttpClient per request would handshake every time).
                val builder = baseClient.newBuilder()
                    .sslSocketFactory(CShieldSSL.getSSLSocketFactory(), CShieldSSL.getTrustManager())
                    .followRedirects(followRedirects)
                    .followSslRedirects(followRedirects)
                    // Re-verify the SPKI pin IN NATIVE CODE, independently of the Java
                    // CShieldTrustManager. It runs after the handshake and BEFORE the request is
                    // sent: if an attacker hooks or replaces the Java TrustManager to skip
                    // pinning, this native step still blocks the MITM.
                    // FAIL-CLOSED: verifyChainNative returns false for a pinned host when the
                    // native side has not received the pins or the JNI call fails. Only a host
                    // that is NOT pinned passes.
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