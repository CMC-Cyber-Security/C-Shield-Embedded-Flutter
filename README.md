# C-Shield Embedded Flutter SDK

C-Shield Embedded protects a Flutter app and its API traffic: every request is signed with a
hardware-backed device key, every response is verified, TLS is pinned, and the device proves its own
integrity to your server. It also ships runtime guards against overlays, auto-clickers, keyloggers,
and on-device malware.

The plugin is a thin Dart layer over the native C-Shield SDKs (AAR on Android, XCFramework on iOS),
so all cryptography runs natively.

## Features

| Feature | What it does | Android | iOS | Guide |
|---|---|:---:|:---:|---|
| **AIP** - API Integrity Protection | Signs requests, verifies responses | ✅ | ✅ | [aip.md](https://github.com/CMC-Cyber-Security/C-Shield-Embedded-Flutter/blob/main/doc/aip.md) |
| **Attestation** - device trust | Hardware-backed trust level, raised on demand | ✅ L0–L5 | ✅ L0–L4 | [attestation.md](https://github.com/CMC-Cyber-Security/C-Shield-Embedded-Flutter/blob/main/doc/attestation.md) |
| **SSL pinning** | SPKI certificate pinning, multi-host | ✅ | ✅ | [ssl-pinning.md](https://github.com/CMC-Cyber-Security/C-Shield-Embedded-Flutter/blob/main/doc/ssl-pinning.md) |
| **Malware scan** | Scans installed apps and APK files | ✅ | - | [malware.md](https://github.com/CMC-Cyber-Security/C-Shield-Embedded-Flutter/blob/main/doc/malware.md) |
| **Anti-overlay** | Blocks tapjacking on sensitive screens | ✅ | - | [anti-overlay.md](https://github.com/CMC-Cyber-Security/C-Shield-Embedded-Flutter/blob/main/doc/anti-overlay.md) |
| **Behavioral touch guard** | Detects auto-clickers and injected taps | ✅ | - | [behavioral-touch-guard.md](https://github.com/CMC-Cyber-Security/C-Shield-Embedded-Flutter/blob/main/doc/behavioral-touch-guard.md) |
| **Anti-keylogger** | Detects untrusted keyboards and accessibility services | ✅ | keyboard only | [anti-keylogger.md](https://github.com/CMC-Cyber-Security/C-Shield-Embedded-Flutter/blob/main/doc/anti-keylogger.md) |

Events and error codes shared by all features are in
[events-and-errors.md](https://github.com/CMC-Cyber-Security/C-Shield-Embedded-Flutter/blob/main/doc/events-and-errors.md).

## Requirements

- Flutter 3.10+, Dart 3.0+
- Android: `minSdk` 24, `compileSdk` 34+
- iOS: 13.0+, Xcode 15+, CocoaPods
- **A C-Shield license and the native SDK binaries from CMC CShield.** The plugin does not bundle
  them: they are built per customer and you add them to your host app. Please contact https://cmccybersecurity.com/giai-phap/giai-phap-bao-ve-ung-dung-di-dong-c-shield/ for details.
- **A physical device.** Attestation relies on the device's secure hardware, so an app that
  integrates this SDK cannot be run on an emulator. Develop and test on a real device.

## Installation

**1. Add the package**

```yaml
dependencies:
  c_shield_embedded: ^1.0.4
```

**2. Add the native binaries to your host app**

- Android - place the AAR files in `android/app/libs/` and declare them in Gradle:
  [Android setup](https://github.com/CMC-Cyber-Security/C-Shield-Embedded-Flutter/blob/main/doc/android-host-app-integration.md)
- iOS - add the XCFrameworks, a `Podfile` hook, and a Run Script phase:
  [iOS setup](https://github.com/CMC-Cyber-Security/C-Shield-Embedded-Flutter/blob/main/doc/ios-host-app-integration.md)

## Quick start

This is the recommended setup: Dio with native SSL pinning and automatic request signing.

```dart
import 'package:c_shield_embedded/c_shield_embedded.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';

late final Dio dio;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 1. Start the SDK. Device attestation begins in the background.
  await CShieldEmbedded.initialize(
    license: 'your_c_shield_license',
    cloudProjectNumber: '123456789012', // Android Play Integrity; omit to disable it
  );

  // 2. Pin your API host. Declare every pinned host in this one call.
  await CShieldSSL.configureHosts(pinsByHost: {
    'api.example.com': [
      'sha256/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=', // intermediate CA
      'sha256/BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB=', // backup
    ],
  });

  // 3. One Dio instance for all protected API calls.
  dio = Dio(BaseOptions(baseUrl: 'https://api.example.com'));
  dio.httpClientAdapter = CShieldSSL.createDioAdapter();
  dio.interceptors.add(CShieldDioInterceptor(dio: dio));

  runApp(const MyApp());
}
```

From here on, `dio.get(...)` / `dio.post(...)` are pinned, signed, and verified with no further code.

Using the `http` package instead of `Dio`? See
[aip.md](https://github.com/CMC-Cyber-Security/C-Shield-Embedded-Flutter/blob/main/doc/aip.md#http-package)
- and note that pinning on the `http` path is weaker than on `Dio`.

### Before a sensitive flow

Ordinary requests need nothing extra. For a route your server protects with a higher trust level
(payment, transfer, login), raise trust first:

```dart
switch (await CShieldAttest.ensureTrust(TrustLevel.l4)) {
  case EnsureTrustResult.satisfied:
    await goToPayment();
  case EnsureTrustResult.insufficient:
    showBlocked('This device does not meet the required security level');
  case EnsureTrustResult.offline:
    showError('Check your internet connection');
  case EnsureTrustResult.rateLimited:
  case EnsureTrustResult.timeout:
    showRetryLater();
  case EnsureTrustResult.unavailable:
    showNotSupported();
}
```

Details, including how to let the interceptor do this per route:
[attestation.md](https://github.com/CMC-Cyber-Security/C-Shield-Embedded-Flutter/blob/main/doc/attestation.md).

### Handling errors

Every SDK failure is a `CShieldException` with a typed `code`. With Dio it arrives as
`DioException.error`:

```dart
try {
  await dio.post('/api/v1/login', data: {'user': 'alice'});
} on DioException catch (e) {
  final error = e.error;
  if (error is CShieldException) {
    switch (error.code) {
      case CShieldErrorCode.sslPinMismatch:
        logSecurityEvent('Pin mismatch'); // MITM, or the pins need rotating
      case CShieldErrorCode.aipInvalidSignature:
        logSecurityEvent('Response tampered');
      case CShieldErrorCode.notReady:
        showRetry(); // attestation not finished yet - see error.retryable
      default:
        debugPrint('C-Shield: ${error.code.name} - ${error.message}');
    }
  }
}
```

The full list of codes is in
[events-and-errors.md](https://github.com/CMC-Cyber-Security/C-Shield-Embedded-Flutter/blob/main/doc/events-and-errors.md).

## Documentation

| Guide | Covers |
|---|---|
| [Android setup](https://github.com/CMC-Cyber-Security/C-Shield-Embedded-Flutter/blob/main/doc/android-host-app-integration.md) | AAR files, Gradle |
| [iOS setup](https://github.com/CMC-Cyber-Security/C-Shield-Embedded-Flutter/blob/main/doc/ios-host-app-integration.md) | XCFrameworks, Podfile, Xcode, troubleshooting |
| [AIP](https://github.com/CMC-Cyber-Security/C-Shield-Embedded-Flutter/blob/main/doc/aip.md) | **Step-by-step integration guide**: signing requests, app start, sensitive routes, error handling |
| [Attestation](https://github.com/CMC-Cyber-Security/C-Shield-Embedded-Flutter/blob/main/doc/attestation.md) | Trust levels, readiness, `ensureTrust`, server error codes |
| [Signing protocol](https://github.com/CMC-Cyber-Security/C-Shield-Embedded-Flutter/blob/main/doc/signing-protocol.md) | Wire format of the request proof and the response signature, for server-side reference |
| [Samples](https://github.com/CMC-Cyber-Security/C-Shield-Embedded-Flutter/blob/main/example/lib/samples) | One runnable Dart file per scenario |
| [SSL pinning](https://github.com/CMC-Cyber-Security/C-Shield-Embedded-Flutter/blob/main/doc/ssl-pinning.md) | Getting pins, multi-host, rotation, limitations |
| [Malware scan](https://github.com/CMC-Cyber-Security/C-Shield-Embedded-Flutter/blob/main/doc/malware.md) | Device scan, single app / APK analysis |
| [Anti-overlay](https://github.com/CMC-Cyber-Security/C-Shield-Embedded-Flutter/blob/main/doc/anti-overlay.md) | Tapjacking guard for sensitive screens |
| [Behavioral touch guard](https://github.com/CMC-Cyber-Security/C-Shield-Embedded-Flutter/blob/main/doc/behavioral-touch-guard.md) | Auto-click detection for sensitive screens |
| [Anti-keylogger](https://github.com/CMC-Cyber-Security/C-Shield-Embedded-Flutter/blob/main/doc/anti-keylogger.md) | Keyboard and accessibility-service detection |
| [Events and errors](https://github.com/CMC-Cyber-Security/C-Shield-Embedded-Flutter/blob/main/doc/events-and-errors.md) | `CShieldEmbedded.events`, license events, `CShieldException` |

A runnable sample app is in
[`example/`](https://github.com/CMC-Cyber-Security/C-Shield-Embedded-Flutter/tree/main/example).

## License

See [LICENSE](https://github.com/CMC-Cyber-Security/C-Shield-Embedded-Flutter/blob/main/LICENSE) and
[NATIVE_COMPONENTS_LICENSE.md](https://github.com/CMC-Cyber-Security/C-Shield-Embedded-Flutter/blob/main/NATIVE_COMPONENTS_LICENSE.md).
