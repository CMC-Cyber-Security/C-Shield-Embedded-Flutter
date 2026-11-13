import Flutter
import UIKit
import CShieldEmbedded

/// Mirrors CShieldEmbeddedPlugin.kt (android) — keep both in sync.
public class CShieldEmbeddedPlugin: NSObject, FlutterPlugin, FlutterStreamHandler {

    private let sslBridge = SslBridge()
    private let aipBridge = AipBridge()
    private let attestBridge = AttestBridge()
    // Forwards native anti-keylogger detections to Dart; reads `eventSink` lazily.
    private lazy var antiKeyloggerBridge = AntiKeyloggerBridge(eventSink: { [weak self] in self?.eventSink })

    // Streams native SDK events (license lifecycle, attestation state, keyboard detections) to
    // Dart over the "c_shield_embedded_event" EventChannel.
    private var eventSink: FlutterEventSink?

    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(name: "c_shield_embedded", binaryMessenger: registrar.messenger())
        let eventChannel = FlutterEventChannel(name: "c_shield_embedded_event", binaryMessenger: registrar.messenger())
        let instance = CShieldEmbeddedPlugin()
        registrar.addMethodCallDelegate(instance, channel: channel)
        eventChannel.setStreamHandler(instance)
    }

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "sdk.initialize":
            let args = call.arguments as? [String: Any] ?? [:]
            guard let license = args["license"] as? String else { result(invalidArg()); return }
            // `cloudProjectNumber` is for Play Integrity (Android) only; iOS (App Attest) IGNORES it.
            // Wire the anti-keylogger detection before init so a keyboard loaded at
            // launch is routed to Dart rather than the SDK's default warning.
            antiKeyloggerBridge.wireDetection()
            CShield.initialize(license: license)
            CShield.setLicenseCallback(self)
            registerAttestStateListener()
            result(nil)
        case let m where m.hasPrefix("ssl."):
            sslBridge.handle(call: call, result: result)
        case let m where m.hasPrefix("aip."):
            aipBridge.handle(call: call, result: result)
        case let m where m.hasPrefix("antiKeylogger."):
            antiKeyloggerBridge.handle(call: call, result: result)
        case let m where m.hasPrefix("attest."):
            // Attestation (App Attest registration/refresh + trust L0–L4). AttestBridge mirrors
            // AttestBridge.kt. iOS reaches L4 at most (Secure Enclave, no StrongBox).
            attestBridge.handle(call: call, result: result)
        case let m where m.hasPrefix("malware."):
            // Anti-malware exists on Android only (AntiMalwareBridge.kt): the iOS sandbox does not
            // let an app scan other apps. Return an EXPLICIT error instead of
            // FlutterMethodNotImplemented (which surfaces as a bare MissingPluginException).
            result(FlutterError(code: CShieldErrorCode.unsupportedPlatform,
                                message: "\(m) is not supported on iOS (sandbox does not allow scanning other apps)",
                                details: nil))
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    // MARK: - FlutterStreamHandler
    //
    // Pushes attestation state changes (onAttestStateChanged) to Dart (CShieldAttest.stateChanges).
    // EVENT-DRIVEN through `CShield.addStateListener`, exactly like Android
    // (CShieldSDK.addStateListener); there is no polling. The listener is registered ONCE, after
    // the first initialize; `onListen` re-emits the current state because Dart usually subscribes
    // AFTER initialize.

    private var attestListenerToken: CShield.StateListenerToken?

    private func registerAttestStateListener() {
        guard attestListenerToken == nil else { return }  // a hot restart calls initialize again
        attestListenerToken = CShield.addStateListener { [weak self] state in
            self?.emitAttestState(state)
        }
    }

    public func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        eventSink = events
        if attestListenerToken != nil { emitAttestState(CShield.state()) }
        return nil
    }

    public func onCancel(withArguments arguments: Any?) -> FlutterError? {
        eventSink = nil
        return nil
    }

    deinit {
        if let token = attestListenerToken { CShield.removeStateListener(token) }
    }

    /// The listener runs on an internal SDK thread → hop to main (an EventSink must be called on main).
    private func emitAttestState(_ state: CShieldState) {
        DispatchQueue.main.async { [weak self] in
            guard let sink = self?.eventSink else { return }
            sink([
                "event": "onAttestStateChanged",
                "state": AttestBridge.stateId(state),
                "trustLevel": AttestBridge.trustId(CShield.currentTrustLevel()),
                "lastError": CShield.lastError() ?? NSNull(),
            ] as [String: Any])
        }
    }

    private func invalidArg() -> FlutterError {
        FlutterError(code: CShieldErrorCode.invalidArgument, message: "Missing or invalid arguments", details: nil)
    }
}

// MARK: - LicenseCallback

extension CShieldEmbeddedPlugin: LicenseCallback {
    public func onLicenseRenewed(_ newJwt: String) {
        // EventSink must be invoked on the main thread.
        DispatchQueue.main.async {
            self.eventSink?(["event": "onLicenseRenewed", "newJwt": newJwt])
        }
    }

    public func onLicenseRevoked() {
        DispatchQueue.main.async {
            self.eventSink?(["event": "onLicenseRevoked"])
        }
    }
}
