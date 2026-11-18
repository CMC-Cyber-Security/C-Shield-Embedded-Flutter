import Flutter
import UIKit
import CShieldEmbedded

/// iOS-only: there is no Android counterpart.
///
/// Forwards `CShieldCaptureDetector` screen-capture detections to Dart as
/// `onScreenCaptureDetected` and exposes the opt-in capture protection.
final class ScreenCaptureBridge {
    private let eventSink: () -> FlutterEventSink?

    init(eventSink: @escaping () -> FlutterEventSink?) {
        self.eventSink = eventSink
    }

    /// Sends `onScreenCaptureDetected` to Dart on the main thread.
    func emitDetected() {
        DispatchQueue.main.async { [weak self] in
            self?.eventSink()?(["event": "onScreenCaptureDetected"])
        }
    }

    /// Re-sends the event when capture is already running, since the SDK's startup check can fire before Dart listens.
    func emitIfCapturing() {
        let isCaptured = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .contains { $0.screen.isCaptured }
        if isCaptured { emitDetected() }
    }

    func handle(call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "screenCapture.enableProtection":
            CShieldCaptureDetector.enableScreenCaptureProtection()
            result(nil)
        default:
            result(FlutterMethodNotImplemented)
        }
    }
}
