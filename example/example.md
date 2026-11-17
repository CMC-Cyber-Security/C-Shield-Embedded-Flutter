# C-Shield Embedded samples

The example app is a menu with one screen per scenario. Each sample is a single file that imports
nothing from the other samples: a comment describing the scenario, then the code to copy (top-level
functions), then a small screen built from plain Flutter widgets.

Setup shared by every sample (`initialize()` and SSL pinning) is in
[main.dart](https://github.com/CMC-Cyber-Security/C-Shield-Embedded-Flutter/blob/main/example/lib/main.dart).

## Protecting API calls

| Scenario | File |
|---|---|
| Sign every request with Dio. **Start here** | [basic_dio.dart](https://github.com/CMC-Cyber-Security/C-Shield-Embedded-Flutter/blob/main/example/lib/samples/basic_dio.dart) |
| The same with `package:http` | [basic_http.dart](https://github.com/CMC-Cyber-Security/C-Shield-Embedded-Flutter/blob/main/example/lib/samples/basic_http.dart) |
| App start: wait for attestation, status banner | [startup_readiness.dart](https://github.com/CMC-Cyber-Security/C-Shield-Embedded-Flutter/blob/main/example/lib/samples/startup_readiness.dart) |
| Raise trust before a payment or transfer (`ensureTrust`) | [sensitive_flow.dart](https://github.com/CMC-Cyber-Security/C-Shield-Embedded-Flutter/blob/main/example/lib/samples/sensitive_flow.dart) |
| Let the interceptor raise trust per route (`requiredLevel`) | [required_level.dart](https://github.com/CMC-Cyber-Security/C-Shield-Embedded-Flutter/blob/main/example/lib/samples/required_level.dart) |
| Sign only some requests (`signWhen`) | [selective_signing.dart](https://github.com/CMC-Cyber-Security/C-Shield-Embedded-Flutter/blob/main/example/lib/samples/selective_signing.dart) |
| Turn SDK and server errors into user messages | [error_handling.dart](https://github.com/CMC-Cyber-Security/C-Shield-Embedded-Flutter/blob/main/example/lib/samples/error_handling.dart) |
| Sign and verify without an interceptor (advanced) | [manual_signing.dart](https://github.com/CMC-Cyber-Security/C-Shield-Embedded-Flutter/blob/main/example/lib/samples/manual_signing.dart) |

## Runtime guards

| Scenario | File |
|---|---|
| Untrusted keyboard / accessibility service | [anti_keylogger.dart](https://github.com/CMC-Cyber-Security/C-Shield-Embedded-Flutter/blob/main/example/lib/samples/anti_keylogger.dart) |
| Tapjacking guard (Android) | [anti_overlay.dart](https://github.com/CMC-Cyber-Security/C-Shield-Embedded-Flutter/blob/main/example/lib/samples/anti_overlay.dart) |
| Auto-click detection (Android) | [touch_guard.dart](https://github.com/CMC-Cyber-Security/C-Shield-Embedded-Flutter/blob/main/example/lib/samples/touch_guard.dart) |
| Malware scan (Android) | [malware_scan.dart](https://github.com/CMC-Cyber-Security/C-Shield-Embedded-Flutter/blob/main/example/lib/samples/malware_scan.dart) |

## Running

```bash
cd example
flutter run                                        # physical device required
flutter run --dart-define=NO_PLAY_INTEGRITY=true   # Android: start without cloudProjectNumber
```

The step-by-step guide that these samples belong to:
[doc/aip.md](https://github.com/CMC-Cyber-Security/C-Shield-Embedded-Flutter/blob/main/doc/aip.md).
