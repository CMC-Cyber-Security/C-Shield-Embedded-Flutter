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

    // Streams native license lifecycle callbacks to Dart over the "c_shield_embedded_event" EventChannel.
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
            // `cloudProjectNumber` chỉ dành cho Play Integrity (Android) — iOS (App Attest) BỎ QUA.
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
            // Attest v2 (register/refresh App Attest + trust L0–L4) đã có trên iOS embedded →
            // AttestBridge mirror AttestBridge.kt. iOS tối đa L4 (Secure Enclave, không StrongBox).
            attestBridge.handle(call: call, result: result)
        case let m where m.hasPrefix("malware."):
            // Anti-malware chỉ có trên Android (AntiMalwareBridge.kt): iOS sandbox không cho app quét
            // app khác. Trả lỗi RÕ RÀNG thay vì FlutterMethodNotImplemented (MissingPluginException âm thầm).
            result(FlutterError(code: CShieldErrorCode.unsupportedPlatform,
                                message: "\(m) is not supported on iOS (sandbox does not allow scanning other apps)",
                                details: nil))
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    // MARK: - FlutterStreamHandler
    //
    // Đẩy đổi trạng thái attestation (onAttestStateChanged) lên Dart (CShieldAttest.stateChanges) —
    // EVENT-DRIVEN qua `CShield.addStateListener`, y hệt Android (CShieldSDK.addStateListener), thay cho
    // poll 1s trước đây. Listener đăng ký MỘT lần sau initialize đầu tiên; `onListen` bắn lại trạng thái
    // hiện tại vì Dart thường subscribe SAU initialize.

    private var attestListenerToken: CShield.StateListenerToken?

    private func registerAttestStateListener() {
        guard attestListenerToken == nil else { return }  // hot-restart gọi lại initialize
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

    /// Listener chạy trên thread nội bộ của SDK → chuyển về main (EventSink bắt buộc main).
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
