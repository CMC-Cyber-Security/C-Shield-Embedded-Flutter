# Events and Errors

Two things are shared by every feature of the SDK: the `CShieldEmbedded.events` stream and the
`CShieldException` type.

- [Events](#events)
- [License lifecycle](#license-lifecycle)
- [Errors](#errors)

---

## Events

`CShieldEmbedded.events` is a broadcast `Stream<CShieldEvent>`. `CShieldEvent` is a sealed class,
so a `switch` over it is checked by the compiler.

```dart
import 'dart:async';

import 'package:c_shield_embedded/c_shield_embedded.dart';

StreamSubscription<CShieldEvent>? _sub;

void listenToCShield() {
  _sub = CShieldEmbedded.events.listen((event) {
    switch (event) {
      case LicenseRenewed(:final newJwt):
        debugPrint('License renewed: $newJwt');
      case LicenseRevoked():
        debugPrint('License revoked');
      case AttestStateChanged(:final state, :final trustLevel):
        debugPrint('Attestation: ${state.name}, trust ${trustLevel.name}');
      case OverlayDetected():
      case OverlayCleared():
      case SuspiciousTouchDetected():
      case TouchGuardCleared():
      case ThirdPartyKeyboardDetected():
      case SuspiciousAccessibilityServiceDetected():
        break;
    }
  });
}

// When no longer needed, for example in dispose():
await _sub?.cancel();
```

- **Subscribe after `initialize()`.** Before that the native side is not wired up and nothing is
  delivered.
- It is a broadcast stream, so any number of listeners is fine.
- Listing every case, as above, means a future SDK version that adds an event will not compile
  until you handle it. Add `default: break;` if you would rather ignore new events.

### All events

| Event | Fields | Platforms | Guide |
|---|---|---|---|
| `LicenseRenewed` | `newJwt` | Android, iOS | [below](#license-lifecycle) |
| `LicenseRevoked` | — | Android, iOS | [below](#license-lifecycle) |
| `AttestStateChanged` | `state`, `trustLevel`, `lastError` | Android, iOS | [attestation.md](attestation.md#readiness) |
| `OverlayDetected` | `fullyObscured`, `partiallyObscured` | Android | [anti-overlay.md](anti-overlay.md) |
| `OverlayCleared` | — | Android | [anti-overlay.md](anti-overlay.md) |
| `SuspiciousTouchDetected` | `riskScore`, `reasons` | Android | [behavioral-touch-guard.md](behavioral-touch-guard.md) |
| `TouchGuardCleared` | — | Android | [behavioral-touch-guard.md](behavioral-touch-guard.md) |
| `ThirdPartyKeyboardDetected` | `inputMethodId`, `packageName`, `label` | Android, iOS | [anti-keylogger.md](anti-keylogger.md) |
| `SuspiciousAccessibilityServiceDetected` | `packageNames` | Android | [anti-keylogger.md](anti-keylogger.md) |

For attestation only, `CShieldAttest.stateChanges` is the same stream already filtered to
`AttestStateChanged`.

---

## License lifecycle

The server can renew or revoke your license while the app is running.

| Event | Meaning | Typical reaction |
|---|---|---|
| `LicenseRenewed(newJwt)` | The license was refreshed. `newJwt` is the new token | Store or forward the new token |
| `LicenseRevoked()` | The license was revoked | Disable protected features, or sign the user out |

---

## Errors

Every failure from the SDK is a `CShieldException`:

```dart
class CShieldException implements Exception {
  final CShieldErrorCode code;  // what went wrong
  final String message;         // description
  final Object? nativeCause;    // underlying native error, if any
  final bool? retryable;        // notReady only
  final String? state;          // notReady only: INITIALIZING / READY / DEGRADED / UNAVAILABLE
}
```

### Error codes

| Code | Cause |
|---|---|
| `notInitialized` | An API was called before `CShieldEmbedded.initialize()` |
| `notReady` | Attestation was not ready when a request had to be signed. See [below](#notready) |
| `playIntegrityNotConfigured` | `ensureTrust` was called but `initialize` got no `cloudProjectNumber`. Android only. See [attestation.md](attestation.md#running-without-play-integrity-android) |
| `aipSigningFailed` | The request could not be signed |
| `aipMissingHeader` | A `2xx` response has no `cs-timestamp` / `cs-signature` header |
| `aipTimestampExpired` | Response timestamp outside the ±30 second window |
| `aipInvalidSignature` | Response signature is invalid: the response was tampered with |
| `aipDetectProxyCA` | A proxy CA was detected; AIP refuses to proceed |
| `sslNotConfigured` | A pinned client or adapter was created before `CShieldSSL.configure()`, or `updatePins` was called on a sealed pin set |
| `sslPinMismatch` | The server certificate matches none of the configured pins |
| `unsupportedPlatform` | The feature does not exist on this platform, for example `CShieldMalware` on iOS |
| `invalidArgument` | An argument was invalid |
| `nativeError` | An unclassified error from the native SDK |

`CShieldErrorCode` is an enum. If you `switch` over it without a `default`, upgrading to an SDK
version that adds a code is a compile error until you add the case.

### notReady

`notReady` carries two extra fields that tell you what to do:

| `retryable` | Meaning | Action |
|---|---|---|
| `true` | Attestation is still in progress, or hit a transient problem | Wait with `CShieldAttest.awaitReady()`, then retry |
| `false` | Permanent. `state` is `UNAVAILABLE` | Do not retry. `message` holds the stable reason code, such as `device_blocked` or `device_unsupported` |

How the interceptors treat `notReady` is set by their
[`onNotReady`](aip.md#step-2-wait-for-the-sdk-at-app-start) option.

### Catching errors

With Dio, the exception is wrapped in a `DioException`:

```dart
try {
  await dio.post('/api/v1/login', data: {'user': 'alice'});
} on DioException catch (e) {
  final error = e.error;
  if (error is! CShieldException) rethrow;

  switch (error.code) {
    case CShieldErrorCode.aipTimestampExpired:
      showError('Please check the date and time on your device');
    case CShieldErrorCode.aipInvalidSignature:
      logSecurityEvent('Response tampered');
    case CShieldErrorCode.sslPinMismatch:
      logSecurityEvent('SSL pin mismatch');
    case CShieldErrorCode.notReady when error.retryable == true:
      showRetry();
    default:
      showError('Security error: ${error.message}');
  }
}
```

With the `http` package and with direct API calls, catch it directly:

```dart
try {
  final response = await client.post(Uri.parse('https://api.example.com/login'));
} on CShieldException catch (e) {
  debugPrint('[${e.code.name}] ${e.message}');
}
```

### Results that are not exceptions

Two outcomes are reported as values instead of being thrown:

- `CShieldAttest.ensureTrust` returns an
  [`EnsureTrustResult`](attestation.md#raising-trust).
- A permanently unusable device shows up as `CShieldState.unavailable`, with the reason in
  `CShieldAttest.lastError()`. See [attestation.md](attestation.md#readiness).
