import Flutter
import UIKit
import CShieldEmbedded

/// Mirrors CShieldEmbeddedPlugin.kt (android) — keep both in sync.
public class CShieldEmbeddedPlugin: NSObject, FlutterPlugin, FlutterStreamHandler {

    private let sslBridge = SslBridge()
    private let aipBridge = AipBridge()
    private let attestBridge = AttestBridge()

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
            CShield.initialize(license: license)
            CShield.setLicenseCallback(self)
            result(nil)
        case let m where m.hasPrefix("ssl."):
            sslBridge.handle(call: call, result: result)
        case let m where m.hasPrefix("aip."):
            aipBridge.handle(call: call, result: result)
        case let m where m.hasPrefix("attest."):
            // Attest v2 (register/refresh App Attest + trust L0–L4) đã có trên iOS embedded →
            // AttestBridge mirror AttestBridge.kt. iOS tối đa L4 (Secure Enclave, không StrongBox).
            attestBridge.handle(call: call, result: result)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    // MARK: - FlutterStreamHandler
    //
    // Đẩy sự kiện đổi trạng thái attestation (onAttestStateChanged) lên Dart (CShieldAttest.stateChanges).
    // Android dùng CShieldSDK.addStateListener (event-driven); iOS `CShield` chưa phơi listener công khai
    // (chỉ AttestManager nội bộ) → POLL state mỗi 1s (như sample native iOS), phát NGAY state hiện tại
    // lúc đăng ký + phát khi state/trust/lastError đổi. Reads không block nên an toàn trên main.

    private var attestTimer: Timer?
    private var lastAttestState: String?
    private var lastAttestTrust: String?
    private var lastAttestError: String?

    public func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        eventSink = events
        // Reset snapshot để phát ngay sự kiện đầu tiên với trạng thái hiện tại.
        lastAttestState = nil; lastAttestTrust = nil; lastAttestError = nil
        emitAttestIfChanged()
        attestTimer?.invalidate()
        attestTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.emitAttestIfChanged()
        }
        return nil
    }

    public func onCancel(withArguments arguments: Any?) -> FlutterError? {
        attestTimer?.invalidate()
        attestTimer = nil
        eventSink = nil
        return nil
    }

    /// Đọc state/trust/lastError hiện tại; phát `onAttestStateChanged` nếu có thay đổi so với lần trước.
    private func emitAttestIfChanged() {
        guard let sink = eventSink else { return }
        let state = AttestBridge.stateId(CShield.state())
        let trust = AttestBridge.trustId(CShield.currentTrustLevel())
        let err = CShield.lastError()
        if state == lastAttestState && trust == lastAttestTrust && err == lastAttestError { return }
        lastAttestState = state; lastAttestTrust = trust; lastAttestError = err
        let payload: [String: Any] = [
            "event": "onAttestStateChanged",
            "state": state,
            "trustLevel": trust,
            "lastError": err ?? NSNull(),
        ]
        sink(payload)
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
