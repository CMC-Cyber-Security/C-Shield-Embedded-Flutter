import Flutter
import UIKit
import CShieldEmbedded

/// Mirrors CShieldEmbeddedPlugin.kt (android) — keep both in sync.
public class CShieldEmbeddedPlugin: NSObject, FlutterPlugin, FlutterStreamHandler {

    private let sslBridge = SslBridge()
    private let aipBridge = AipBridge()

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
            CShield.initialize(license: license)
            CShield.setLicenseCallback(self)
            result(nil)
        case let m where m.hasPrefix("ssl."):
            sslBridge.handle(call: call, result: result)
        case let m where m.hasPrefix("aip."):
            aipBridge.handle(call: call, result: result)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    // MARK: - FlutterStreamHandler

    public func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        eventSink = events
        return nil
    }

    public func onCancel(withArguments arguments: Any?) -> FlutterError? {
        eventSink = nil
        return nil
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
