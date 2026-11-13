package com.cmc.c_shield_embedded.c_shield_embedded

import android.app.Activity
import android.content.Context
import android.os.Handler
import android.os.Looper
import com.cmc.c_shield_embedded.c_shield_embedded.bridges.AipBridge
import com.cmc.c_shield_embedded.c_shield_embedded.bridges.AntiMalwareBridge
import com.cmc.c_shield_embedded.c_shield_embedded.bridges.AntiKeyloggerBridge
import com.cmc.c_shield_embedded.c_shield_embedded.bridges.AntiOverlayBridge
import com.cmc.c_shield_embedded.c_shield_embedded.bridges.BehavioralTouchGuardBridge
import com.cmc.c_shield_embedded.c_shield_embedded.bridges.AttestBridge
import com.cmc.c_shield_embedded.c_shield_embedded.bridges.SslBridge
import com.cmc.cshield_embedded.CShieldSDK
import com.cmc.cshield_embedded.CShieldState
import com.cmc.cshield_embedded.license.models.LicenseCallback
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result

/**
 * Android side of the `c_shield_embedded` Flutter plugin. Routes method calls to the feature
 * bridges and streams native SDK events to Dart.
 *
 * Mirrored by CShieldEmbeddedPlugin.swift (iOS) — keep both in sync.
 */
class CShieldEmbeddedPlugin :
    FlutterPlugin,
    MethodCallHandler, EventChannel.StreamHandler, ActivityAware {
    // The MethodChannel that carries method calls between Flutter and native Android.
    //
    // This local reference serves to register the plugin with the Flutter Engine and unregister it
    // when the Flutter Engine is detached.
    private lateinit var channel: MethodChannel

    // Streams native SDK events (license, attestation state, guard detections) to Dart.
    private lateinit var eventChannel: EventChannel
    private var eventSink: EventChannel.EventSink? = null

    // An EventSink MUST be called on the main thread; the attestation listener fires from one of
    // the SDK's background threads.
    private val mainHandler = Handler(Looper.getMainLooper())

    private lateinit var context: Context

    private lateinit var sslBridge: SslBridge
    private lateinit var aipBridge: AipBridge
    private lateinit var attestBridge: AttestBridge
    private lateinit var malwareBridge: AntiMalwareBridge
    private lateinit var antiOverlayBridge: AntiOverlayBridge
    private lateinit var btgBridge: BehavioralTouchGuardBridge
    private lateinit var antiKeyloggerBridge: AntiKeyloggerBridge

    // Set/cleared by the ActivityAware callbacks; the anti-overlay and touch guards need the
    // host Activity to wrap its window callback.
    private var activity: Activity? = null

    // Attestation state listener. The reference is kept so it can be removed on detach (otherwise
    // the old engine would leak). Registered ONCE, after the first initialize: a hot restart calls
    // initialize again and must not register a duplicate.
    private var attestStateListener: ((CShieldState) -> Unit)? = null

    override fun onAttachedToEngine(flutterPluginBinding: FlutterPlugin.FlutterPluginBinding) {
        context = flutterPluginBinding.applicationContext
        channel = MethodChannel(flutterPluginBinding.binaryMessenger, "c_shield_embedded")
        eventChannel = EventChannel(flutterPluginBinding.binaryMessenger, "c_shield_embedded_event")

        sslBridge = SslBridge()
        aipBridge = AipBridge(context)
        attestBridge = AttestBridge()
        malwareBridge = AntiMalwareBridge(context)
        antiOverlayBridge = AntiOverlayBridge({ activity }, { eventSink })
        btgBridge = BehavioralTouchGuardBridge({ activity }, { eventSink })
        antiKeyloggerBridge = AntiKeyloggerBridge { eventSink }
        // Route the auto-started guard's detections to the Dart event channel.
        antiKeyloggerBridge.wireDetection()

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
                // cloudProjectNumber is NULLABLE: omitted (null) ⇒ Play Integrity is off (Key
                // Attestation only) and ensureTrust throws. Present but malformed ⇒
                // IllegalArgumentException.
                val cloudProjectNumber = call.argument<String>("cloudProjectNumber")
                try {
                    CShieldSDK.initialize(context, license, cloudProjectNumber)
                } catch (e: IllegalArgumentException) {
                    // cloudProjectNumber is non-empty but not a positive integer → fail fast, clearly.
                    return result.error(CShieldErrorCode.INVALID_ARGUMENT, e.message, null)
                }
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
            call.method.startsWith("antiOverlay.") -> antiOverlayBridge.handle(call, result)
            call.method.startsWith("btg.") -> btgBridge.handle(call, result)
            call.method.startsWith("antiKeylogger.") -> antiKeyloggerBridge.handle(call, result)
            else -> result.notImplemented()
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
        attestStateListener?.let { CShieldSDK.removeStateListener(it) }
        attestStateListener = null
    }

    /**
     * Pushes attestation state changes to Dart (`CShieldEmbedded.events`) so the app can update
     * its UI or decide whether to wait or block. The SDK calls the listener IMMEDIATELY with the
     * current state on registration; if Dart subscribes later, [onListen] emits it again, so Dart
     * always gets a first state without polling.
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
        // Dart usually subscribes AFTER initialize (for example in initState) and has therefore
        // missed the listener's first emission → re-emit the current state as soon as there is a
        // sink, so the UI is not left in an "unknown" state.
        if (attestStateListener != null) emitAttestState(CShieldSDK.state())
    }

    override fun onCancel(arguments: Any?) {
        eventSink = null
    }

    // ── ActivityAware ──────────────────────────────────────────────────────────
    // Track the host Activity so the anti-overlay and touch-guard bridges can harden its window.

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activity = binding.activity
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        activity = binding.activity
    }

    override fun onDetachedFromActivityForConfigChanges() {
        activity = null
    }

    override fun onDetachedFromActivity() {
        activity = null
    }
}
