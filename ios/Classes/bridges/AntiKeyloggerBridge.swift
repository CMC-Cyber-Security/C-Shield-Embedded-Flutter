import Flutter
import CShieldEmbedded

/// Mirrors AntiKeyloggerBridge.kt (android) — keep both in sync.
///
/// iOS exposes the anti-keylogger via the native `CShieldCaptureDetector`, which
/// blocks third-party keyboard extensions and reports them. This bridge wires that
/// detection to Dart over the shared event channel as `onThirdPartyKeyboardDetected`
/// (the iOS analog of the Android `ThirdPartyKeyboardDetected` event).
///
/// Unlike Android, iOS has no keyboard allowlist to configure and no on-demand
/// re-check — the guard is event-driven — so `configure` / `runCheck` are accepted
/// as no-ops to keep shared Dart code working. iOS never emits the accessibility
/// event (there is no accessibility-keylogger concept on the platform).
final class AntiKeyloggerBridge {
    private let eventSink: () -> FlutterEventSink?

    init(eventSink: @escaping () -> FlutterEventSink?) {
        self.eventSink = eventSink
    }

    /// Routes native keyboard detections to Dart. Call once (before SDK init).
    func wireDetection() {
        CShieldCaptureDetector.onDetection = { [weak self] event in
            switch event {
            case .thirdPartyKeyboardBlocked:
                // EventSink must be invoked on the main thread.
                DispatchQueue.main.async {
                    self?.eventSink()?([
                        "event": "onThirdPartyKeyboardDetected",
                        // iOS does not expose the keyboard extension's identity.
                        "inputMethodId": "",
                        "packageName": "",
                        "label": "Third-party Keyboard",
                    ])
                }
            case .screenCaptureDetected:
                break // not part of the anti-keylogger feature
            @unknown default:
                break
            }
        }
    }

    func handle(call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        // No allowlist / manual re-check on iOS — keyboard blocking is automatic
        // and event-driven. Accept as no-ops so shared Dart code keeps working.
        case "antiKeylogger.configure", "antiKeylogger.runCheck":
            result(nil)
        default:
            result(FlutterMethodNotImplemented)
        }
    }
}
