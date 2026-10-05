package com.cmc.c_shield_embedded.c_shield_embedded

import android.content.Context
import com.cmc.c_shield_embedded.c_shield_embedded.bridges.AipBridge
import com.cmc.c_shield_embedded.c_shield_embedded.bridges.AntiMalwareBridge
import com.cmc.c_shield_embedded.c_shield_embedded.bridges.SslBridge
import com.cmc.cshield_embedded.CShieldSDK
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

    private lateinit var context: Context

    private lateinit var sslBridge: SslBridge
    private lateinit var aipBridge: AipBridge
    private lateinit var malwareBridge: AntiMalwareBridge

    override fun onAttachedToEngine(flutterPluginBinding: FlutterPlugin.FlutterPluginBinding) {
        context = flutterPluginBinding.applicationContext
        channel = MethodChannel(flutterPluginBinding.binaryMessenger, "c_shield_embedded")
        eventChannel = EventChannel(flutterPluginBinding.binaryMessenger, "c_shield_embedded_event")

        sslBridge = SslBridge()
        aipBridge = AipBridge(context)
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
                result.success(null)
            }
            call.method.startsWith("ssl.") -> sslBridge.handle(call, result)
            call.method.startsWith("aip.") -> aipBridge.handle(call, result)
            call.method.startsWith("malware.") -> malwareBridge.handle(call, result)
            else -> result.notImplemented()
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
    }

    override fun onListen(
        arguments: Any?,
        events: EventChannel.EventSink?
    ) {
        eventSink = events
    }

    override fun onCancel(arguments: Any?) {
        eventSink = null
    }
}
