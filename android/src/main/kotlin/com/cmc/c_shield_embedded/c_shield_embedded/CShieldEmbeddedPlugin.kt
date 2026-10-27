package com.cmc.c_shield_embedded.c_shield_embedded

import android.content.Context
import android.os.Handler
import android.os.Looper
import com.cmc.c_shield_embedded.c_shield_embedded.bridges.AipBridge
import com.cmc.c_shield_embedded.c_shield_embedded.bridges.AntiMalwareBridge
import com.cmc.c_shield_embedded.c_shield_embedded.bridges.AttestBridge
import com.cmc.c_shield_embedded.c_shield_embedded.bridges.SslBridge
import com.cmc.cshield_embedded.CShieldSDK
import com.cmc.cshield_embedded.CShieldState
import com.cmc.cshield_embedded.license.models.LicenseCallback
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result

/** CShieldEmbeddedPlugin */
class CShieldEmbeddedPlugin :
    FlutterPlugin,
    MethodCallHandler, EventChannel.StreamHandler {
    // The MethodChannel that will the communication between Flutter and native Android
    //
    // This local reference serves to register the plugin with the Flutter Engine and unregister it
    // when the Flutter Engine is detached from the Activity
    private lateinit var channel: MethodChannel
    private lateinit var eventChannel: EventChannel
    private var eventSink: EventChannel.EventSink? = null

    // EventSink BẮT BUỘC gọi trên main thread; listener attest bắn từ thread nền của SDK.
    private val mainHandler = Handler(Looper.getMainLooper())

    private lateinit var context: Context

    private lateinit var sslBridge: SslBridge
    private lateinit var aipBridge: AipBridge
    private lateinit var attestBridge: AttestBridge
    private lateinit var malwareBridge: AntiMalwareBridge

    // Listener trạng thái attestation — giữ tham chiếu để gỡ khi detach (tránh rò engine cũ).
    // Đăng ký MỘT lần sau initialize đầu tiên (hot-restart gọi lại initialize, không nhân bản).
    private var attestStateListener: ((CShieldState) -> Unit)? = null

    override fun onAttachedToEngine(flutterPluginBinding: FlutterPlugin.FlutterPluginBinding) {
        context = flutterPluginBinding.applicationContext
        channel = MethodChannel(flutterPluginBinding.binaryMessenger, "c_shield_embedded")
        eventChannel = EventChannel(flutterPluginBinding.binaryMessenger, "c_shield_embedded_event")

        sslBridge = SslBridge()
        aipBridge = AipBridge(context)
        attestBridge = AttestBridge()
        malwareBridge = AntiMalwareBridge(context)

        channel.setMethodCallHandler(this)
        eventChannel.setStreamHandler(this)
    }

    override fun onMethodCall(
        call: MethodCall,
        result: Result
    ) {
        when {
            call.method == "sdk.initialize" -> {
                val license = call.argument<String>("license")
                    ?: return result.error(CShieldErrorCode.INVALID_ARGUMENT, "c-shield license required", null)
                CShieldSDK.initialize(context, license)
                CShieldSDK.setLicenseCallback(object : LicenseCallback {
                    override fun onLicenseRenewed(newJwt: String) {
                        eventSink?.success(mapOf(
                            "event" to "onLicenseRenewed",
                            "newJwt" to newJwt
                        ))
                    }

                    override fun onLicenseRevoked() {
                        eventSink?.success(mapOf(
                            "event" to "onLicenseRevoked"
                        ))
                    }
                })
                registerAttestStateListener()
                result.success(null)
            }
            call.method.startsWith("ssl.") -> sslBridge.handle(call, result)
            call.method.startsWith("aip.") -> aipBridge.handle(call, result)
            call.method.startsWith("attest.") -> attestBridge.handle(call, result)
            call.method.startsWith("malware.") -> malwareBridge.handle(call, result)
            else -> result.notImplemented()
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
        attestStateListener?.let { CShieldSDK.removeStateListener(it) }
        attestStateListener = null
    }

    /**
     * Đẩy đổi trạng thái attestation lên Dart (`CShieldEmbedded.events`) để app cập nhật UI /
     * quyết định chờ hay chặn. SDK gọi listener NGAY với trạng thái hiện tại lúc đăng ký; nếu Dart
     * subscribe muộn hơn thì [onListen] bắn lại — Dart luôn có state đầu tiên mà không cần poll.
     */
    private fun registerAttestStateListener() {
        if (attestStateListener != null) return
        val listener: (CShieldState) -> Unit = ::emitAttestState
        attestStateListener = listener
        CShieldSDK.addStateListener(listener)
    }

    private fun emitAttestState(state: CShieldState) {
        mainHandler.post {
            eventSink?.success(mapOf(
                "event" to "onAttestStateChanged",
                "state" to state.name,
                "trustLevel" to CShieldSDK.currentTrustLevel().name,
                "lastError" to CShieldSDK.lastError()
            ))
        }
    }

    override fun onListen(
        arguments: Any?,
        events: EventChannel.EventSink?
    ) {
        eventSink = events
        // Dart thường subscribe SAU initialize (vd trong initState) nên đã bỏ lỡ phát đầu tiên của
        // listener → bắn lại trạng thái hiện tại ngay khi có sink, để UI không treo ở "chưa biết".
        if (attestStateListener != null) emitAttestState(CShieldSDK.state())
    }

    override fun onCancel(arguments: Any?) {
        eventSink = null
    }
}
