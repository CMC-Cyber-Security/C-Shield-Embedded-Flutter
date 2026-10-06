# C-Shield Embedded Flutter SDK

C-Shield Embedded Flutter SDK provides **AIP (API Integrity Protection)** for Flutter applications, protecting the communication between the app and the server through certificate pinning and request/response signing.

The SDK wraps native AAR (Android) and XCFramework (iOS) libraries, so the signing/verification layer always runs natively.

---

## Table of Contents

1. [Integrating the SDK](#1-integrating-the-sdk)
   - 1.1 [Add dependency to pubspec.yaml](#11-add-dependency-to-pubspecyaml)
   - 1.2 [Android configuration](#12-android-configuration)
   - 1.3 [iOS configuration](#13-ios-configuration)
2. [Initializing the SDK](#2-initializing-the-sdk)
3. [AIP — API Integrity Protection](#3-aip--api-integrity-protection)
   - 3.1 [Automatic mode — CShieldInterceptor (http)](#31-automatic-mode--cshieldinterceptor-http)
   - 3.2 [Automatic mode — CShieldDioInterceptor (Dio)](#32-automatic-mode--cshielddiointerceptor-dio)
   - 3.3 [Manual mode — CShieldAIP](#33-manual-mode--cshieldaip)
   - 3.4 [Signing protocol](#34-signing-protocol)
4. [SSL — Certificate Pinning](#4-ssl--certificate-pinning)
   - 4.1 [Obtaining pin values](#41-obtaining-pin-values)
   - 4.2 [Configuring CShieldSSL](#42-configuring-cshieldssl)
   - 4.3 [Integrating with the http package](#43-integrating-with-the-http-package)
   - 4.4 [Integrating with Dio](#44-integrating-with-dio)
   - 4.5 [Manual verification](#45-manual-verification)
   - 4.6 [Capabilities, limitations, and recommendations](#46-capabilities-limitations-and-recommendations)
5. [Malware — On-Device Threat Scanning](#5-malware--on-device-threat-scanning)
   - 5.1 [Permissions (Android)](#51-permissions-android)
   - 5.2 [Scanning the whole device](#52-scanning-the-whole-device)
   - 5.3 [Analyzing a single app or APK file](#53-analyzing-a-single-app-or-apk-file)
   - 5.4 [Result models](#54-result-models)
   - 5.5 [API reference](#55-api-reference)
6. [Exceptions](#6-exceptions)

---

## 1. Integrating the SDK

### 1.1 Add dependency to pubspec.yaml

Add `c_shield_embedded` to `pubspec.yaml`:

```yaml
dependencies:
  flutter:
    sdk: flutter
  c_shield_embedded: ^1.0.3
```

Then run:

```bash
flutter pub get
```

### 1.2 Android configuration

#### Step 1 — Obtain the AAR files from CMC CShield

The Android SDK is built per customer, using the certificate hash of your signed app. Contact CMC CShield to receive the AAR files matching your app's signing certificate.

#### Step 2 — Place the AAR files into the project

Create a `libs/` folder under `android/app/` and place the AAR files there:

```
your_app_flutter/
└── android/
    └── app/
        └── libs/  ← place the AAR files here
            └── cshield-embedded-release.aar
            └── cshield-embedded-debug.aar
```

#### Step 3 — Declare the dependency in build.gradle

Open `android/app/build.gradle.kts` (or `build.gradle`) and add:

```kotlin
android {
    defaultConfig {
        minSdk = 24       // minimum required by the SDK
    }
    compileSdk = 34       // minimum required by the SDK
}

dependencies {
    // Android SDK — AAR files provided by CMC CShield
    debugImplementation(files("libs/cshield-embedded-debug.aar"))
    releaseImplementation(files("libs/cshield-embedded-release.aar"))
}
```

> No other transitive dependencies are needed — the SDK ships no native UI (no RASP popups), so it doesn't depend on Compose/Retrofit.

#### Step 4 — Build the release AAB

```bash
flutter build appbundle --release
```

### 1.3 iOS configuration

Please follow the steps in the [iOS Integration Guide](https://github.com/CMC-Cyber-Security/C-Shield-Embedded-Flutter/blob/main/doc/ios-host-app-integration.md).

---

## 2. Initializing the SDK

Call `CShieldEmbedded.initialize()` **before `runApp()`** in your `main()` function:

```dart
import 'package:c_shield_embedded/c_shield_embedded.dart';
import 'package:flutter/material.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await CShieldEmbedded.initialize("your_c_shield_license");
  runApp(const MyApp());
}
```

If `initialize()` isn't called before using the other APIs, native behavior isn't guaranteed — always call it before any `CShieldSSL`/`CShieldAIP` call.

### Listening to license lifecycle events

After `initialize()`, the native SDK streams license lifecycle callbacks through `CShieldEmbedded.events` — a broadcast `Stream<CShieldEvent>`. Subscribe to react when the server renews or revokes the license at runtime:

```dart
import 'dart:async';
import 'package:c_shield_embedded/c_shield_embedded.dart';

StreamSubscription<CShieldEvent>? _licenseSub;

void _listenLicenseEvents() {
  _licenseSub = CShieldEmbedded.events.listen((event) {
    switch (event) {
      case LicenseRenewed(:final newJwt):
        // The license was refreshed — persist/forward the new token.
        debugPrint('License renewed: $newJwt');
      case LicenseRevoked():
        // The license was revoked — block protected features / force logout.
        debugPrint('License revoked');
    }
  });
}

// Cancel the subscription when it's no longer needed (e.g. in dispose()).
await _licenseSub?.cancel();
```

> `events` is a broadcast stream, so multiple listeners are allowed. Subscribe **after** `initialize()`, otherwise the native callback isn't wired yet and no events are delivered.

---

## 3. AIP — API Integrity Protection

AIP signs every request sent to the server and verifies the signature of every response received, preventing MITM and replay attacks.

The SDK offers two integration modes:

- **Automatic mode (recommended):** Use `CShieldInterceptor` (for the `http` package) or `CShieldDioInterceptor` (for Dio - recommended). Signing/verification happens fully automatically.
- **Manual mode:** Use `CShieldAIP` directly for full control over payload and timing.

### 3.1 Automatic mode — CShieldInterceptor (http)

```dart
import 'package:c_shield_embedded/c_shield_embedded.dart';
import 'package:http/http.dart' as http;

// Create once, reuse across the whole app
final client = CShieldInterceptor();

// Or combine with SSL pinning:
final client = CShieldInterceptor(
  inner: CShieldSSL.createIOClient(),
);

// Use just like a regular http.Client:
final response = await client.post(
  Uri.parse('https://api.example.com/users'),
  headers: {'Content-Type': 'application/json'},
  body: jsonEncode({'name': 'Alice'}),
);
// cs-timestamp / cs-signature are attached to the request automatically.
// The response signature is verified automatically before it's returned.
```

**`CShieldInterceptor` parameters:**

| Parameter | Type | Default | Description |
|---|---|---|---|
| `inner` | `http.Client?` | `http.Client()` | Inner HTTP client (pass a client with SSL pinning to combine both) |
| `verifyResponses` | `bool` | `true` | Verify the response signature; set `false` if the server doesn't sign responses yet |

### 3.2 Automatic mode — CShieldDioInterceptor (Dio) - Recommended

```dart
import 'package:c_shield_embedded/c_shield_embedded.dart';
import 'package:dio/dio.dart';
import 'package:dio/io.dart';

final dio = Dio(BaseOptions(baseUrl: 'https://api.example.com'));

// Add the AIP interceptor
dio.interceptors.add(const CShieldDioInterceptor());

// Combine with SSL pinning:
dio.httpClientAdapter = CShieldSSL.createDioAdapter();
dio.interceptors.add(const CShieldDioInterceptor());

// Use normally
final response = await dio.post('/api/v1/login', data: {'user': 'alice'});
```

**`CShieldDioInterceptor` parameters:**

| Parameter | Type | Default | Description |
|---|---|---|---|
| `verifyResponses` | `bool` | `true` | Verify the response signature; set `false` if the server doesn't sign responses |

> When `verifyResponses: true`, the interceptor temporarily forces `ResponseType.bytes` to read the raw bytes for verification, then decodes back to the original type before returning to the caller.

### 3.3 Manual mode — CShieldAIP

Use this when you need full control — WebSocket, a custom HTTP client, or detailed payload logging.

```dart
import 'package:c_shield_embedded/c_shield_embedded.dart';

// 1. Sign a request manually
final aipHeaders = await CShieldAIP.signRequest(
  method: 'POST',
  path: '/api/v1/login',    // path only, no query string
  body: Uint8List.fromList(utf8.encode(jsonEncode({'user': 'alice'}))),
  contentType: 'application/json',
);
// aipHeaders = {'cs-timestamp': '...', 'cs-signature': '...'}
// Attach these to the request before sending

// 2. Verify a response manually
await CShieldAIP.verifyResponse(
  statusCode: 200,
  path: '/api/v1/login',
  headers: response.headers,
  body: responseBytes,
);
// No throw = valid; throws CShieldException on failure

// 3. Sign a raw payload (advanced)
final ts = DateTime.now().millisecondsSinceEpoch ~/ 1000;
final norm = await CShieldAIP.normalizeBody(
  body: bodyBytes,
  contentType: 'application/json',
);
final payload = 'POST./api/v1/login.$ts.${norm['hash']}';
final signature = await CShieldAIP.sign(payload);

// 4. Verify a raw signature
await CShieldAIP.verify(payload: payload, signature: signature);
```

**`CShieldAIP` API:**

| Method | Description |
|---|---|
| `signRequest(method, path, body, contentType)` | Signs a request and returns a map `{'cs-timestamp', 'cs-signature'}` |
| `verifyResponse(statusCode, path, headers, body)` | Verifies the response signature; throws `CShieldException` on failure |
| `sign(payload)` | Signs a raw payload; the caller builds the payload string |
| `verify(payload, signature)` | Verifies a raw payload's signature |
| `normalizeBody(body, contentType)` | Normalizes the body and computes its hash; returns `{'normalizedString', 'sizeInBytes', 'hash'}` |

### 3.4 Signing protocol

**Request — sent by the client to the server:**

Attached headers:
```
cs-timestamp: <unix_seconds>
cs-signature: <RSA_signature>
```

Signed payload:
```
{METHOD}.{path}.{timestamp}.{SHA256(body)}
```

Example:
```
POST./api/v1/login.1746700000.e3b0c44298fc1c149afbf4c8996fb924...
```

**Response — returned by the server:**

Headers the server must attach:
```
cs-timestamp: <unix_seconds>
cs-signature: <RSA_signature>
```

Payload the server signs:
```
{statusCode}.{path}.{timestamp}.{SHA256(responseBody)}
```

**Rules:**
- The timestamp must fall within a **±30 second** window of the device clock.
- `path` is the URL path without the query string (`/api/v1/login`, not `/api/v1/login?token=abc`).
- The SHA-256 hash of the body is lowercase hex.

**Body normalization:**

| Content-Type | Handling |
|---|---|
| `application/json` / text | Body bytes are used verbatim |
| `multipart/form-data` | Only text fields are used (file parts are ignored), sorted by field name, serialized as JSON |

---

## 4. SSL — Certificate Pinning

Certificate pinning ensures the app only accepts the known, correct server certificate, preventing MITM even when the device trusts a rogue CA.

### 4.1 Obtaining pin values

A pin is the SHA-256 hash of the certificate's SPKI (Subject Public Key Info), base64-encoded:

```bash
# Get the pin directly from the server
openssl s_client -connect api.example.com:443 -servername api.example.com 2>/dev/null \
  | openssl x509 -pubkey -noout \
  | openssl pkey -pubin -outform DER \
  | openssl dgst -sha256 -binary \
  | openssl base64

# Prefix the result with "sha256/"
# Example: sha256/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=
```

**Recommendation: always provide at least 2 pins** (primary + backup) to avoid lockout when the certificate rotates.

#### Pin the intermediate CA to survive rotation

Leaf certificates are usually **reissued periodically** (Let's Encrypt/Google Trust Services ~90 days) and **may change key on each reissue** → a leaf pin will go stale and **the app will be blocked from connecting** until an update ships. To avoid this, pin the **public key of a stable intermediate CA** (rarely changes for years) instead of, or alongside, the leaf. `createDioAdapter()` matches the pin against the **entire chain**, so any single certificate in the chain matching is enough.

```bash
# View the full chain (leaf + intermediate + root)
openssl s_client -connect api.example.com:443 -servername api.example.com -showcerts </dev/null 2>/dev/null

# For each "BEGIN CERTIFICATE" block (cert #1 = intermediate), compute the SPKI pin:
openssl x509 -in intermediate.pem -pubkey -noout \
  | openssl pkey -pubin -outform DER \
  | openssl dgst -sha256 -binary | openssl base64
```

> ⚠️ **Only the Dio path (`createDioAdapter`) matches the whole chain.** The `http` path and `verifyPin` only compare the leaf (see [4.6](#46-capabilities-limitations-and-recommendations)) — pinning the intermediate will **not** match on those two paths.

### 4.2 Configuring CShieldSSL

Call `configure()` after `initialize()`, before making any network request:

```dart
await CShieldEmbedded.initialize("your_c_shield_license");

await CShieldSSL.configure(
  pins: [
    'sha256/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=', // primary
    'sha256/BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB=', // backup
  ],
  hostname: 'api.example.com',
);
```

**`CShieldSSL` API:**

| Method | Description |
|---|---|
| `configure(pins, hostname)` | Configures pinning; throws `ArgumentError`/`CShieldException(invalidArgument)` if pins are empty, hostname is blank, or a pin lacks the `sha256/` prefix |
| `updatePins(pins, hostname)` | Updates the pins after the server rotates its certificate (alias for `configure`) |
| `isConfigured()` | Returns `true` if already configured |
| `createDioAdapter()` | **(Recommended)** Creates an `HttpClientAdapter` for Dio. Requests to `hostname` are made at the **native** layer (OkHttp/URLSession) → pinning runs at the TLS layer against the **full chain** (leaf/intermediate/root). Other hosts go through the default adapter. |
| `createHttpClient()` | Creates an `HttpClient` (dart:io) with SPKI pinning via `badCertificateCallback`. **Leaf-only, pure Dart** — see the warning in [4.6](#46-capabilities-limitations-and-recommendations) |
| `createIOClient()` | Creates an `IOClient` (http package) — a drop-in for `http.Client()`. **Leaf-only, pure Dart** |
| `verifyPin(certDerBase64, host)` | Manually verifies a single certificate DER, base64-encoded. **Checks only the leaf's SPKI** (Dart can only pass the leaf) |

### 4.3 Integrating with the http package

> ⚠️ **Not recommended for sensitive APIs.** The `http` path uses `badCertificateCallback`, which **only fires when the certificate fails default validation**. A MITM certificate chaining to a trusted CA (even a CA the victim installed themselves) will **pass without pin checking**. It also **only compares the leaf**, so intermediate pinning isn't possible. For sensitive data, use **Dio + `createDioAdapter()`** ([4.4](#44-integrating-with-dio)).

```dart
import 'package:c_shield_embedded/c_shield_embedded.dart';

// Setup (once, in main() or app init)
await CShieldSSL.configure(
  pins: ['sha256/...'],
  hostname: 'api.example.com',
);

// Create the client (reuse it, don't recreate per request)
final client = CShieldSSL.createIOClient();

// Use like a regular http.Client
final response = await client.get(
  Uri.parse('https://api.example.com/data'),
);
```

**Combining SSL pinning + AIP:**

```dart
final client = CShieldInterceptor(
  inner: CShieldSSL.createIOClient(), // SSL pinning at the inner layer
);
// client now has both certificate pinning and automatic AIP signing/verification
```

### 4.4 Integrating with Dio

```dart
import 'package:c_shield_embedded/c_shield_embedded.dart';
import 'package:dio/dio.dart';

await CShieldSSL.configure(
  pins: ['sha256/...'],
  hostname: 'api.example.com',
);

final dio = Dio(BaseOptions(baseUrl: 'https://api.example.com'));

// Attach SSL pinning to Dio. For a configured host, requests are made
// at the NATIVE layer (OkHttp on Android, URLSession on iOS) — where
// the full certificate chain is visible — so pinning can match
// intermediate/root as well. Other hosts go through the default
// adapter (unaffected).
dio.httpClientAdapter = CShieldSSL.createDioAdapter();

// Combine with AIP
dio.interceptors.add(const CShieldDioInterceptor());
```

> **Buffered, not streaming.** Requests/responses are passed through native as a whole. Upload/download progress, `ResponseType.stream`, and SSE are not supported on a pinned host — see [4.6](#46-capabilities-limitations-and-recommendations).

### 4.5 Manual verification

> ⚠️ `verifyPin()` **only checks the leaf certificate's SPKI** (Dart can only pass the leaf down to native) and does not perform full CA chain validation. Treat it as a secondary utility, not the primary pinning mechanism. The complete mechanism (full chain + CA validation) is `createDioAdapter()`.

Use `verifyPin()` in a custom interceptor or WebSocket:

```dart
// Get the DER bytes of the leaf certificate from the TLS connection
final certDerBase64 = base64.encode(peerCertificateDerBytes);

final trusted = await CShieldSSL.verifyPin(
  certDerBase64: certDerBase64,
  host: 'api.example.com',
);

if (!trusted) {
  throw const CShieldException(
    CShieldErrorCode.sslPinMismatch,
    'Certificate pin mismatch for api.example.com',
  );
}
```

### 4.6 Capabilities, limitations, and recommendations

A fundamental Flutter constraint: `dart:io` **only exposes the leaf certificate** — there's no pure-Dart API to obtain the full chain. Because of this, the SDK **delegates transport to native** (OkHttp/URLSession) on the Dio path so pinning runs where the full chain is visible — this is considered the most reliable model available in Flutter.

#### What works today

| Capability | `createDioAdapter` (Dio) | `createIOClient` (http) | `verifyPin` |
|---|---|---|---|
| Matches SPKI across the **full chain** (leaf/intermediate/root) | ✅ | ❌ leaf only | ❌ leaf only |
| Pin the intermediate → resilient to rotation | ✅ | ❌ | ❌ |
| System CA validation (fail-closed) | ✅ (native) | partial¹ | partial |
| Blocks user-installed CAs (Burp/Charles) | ✅ (native) | ❌² | — |

¹ `badCertificateCallback` only runs when default validation fails.
² A MITM cert chaining to a trusted CA will pass through (the callback never fires).

#### Limitations

**A. Inherent to Flutter — nothing the SDK can do about these:**
- **Narrow coverage**: only traffic going through the exact Dio instance with the adapter attached, and only to the configured `hostname`. Pinning does **NOT** cover WebView (`webview_flutter`), image loading (`Image.network`, `CachedNetworkImage`), other HTTP libraries, or third-party plugins. → Route sensitive API calls through the pinned Dio instance.
- **Web builds**: browsers don't allow app-level pinning.
- **Rotation/expiry management**: a pinned certificate that expires breaks the app. Mitigate by pinning the **intermediate** ([4.1](#pin-the-intermediate-ca-to-survive-rotation)) plus a backup pin.

**B. Due to the implementation (native transport on the Dio path):**
- **Buffered, not streaming**: no upload/download progress, no `ResponseType.stream`, no SSE. Large files can consume significant RAM → use a non-pinned Dio instance for these cases.
- **`CancelToken` can't cancel the native request**: Dio cancels on the Dart side, but the native request keeps running until it completes.
- **iOS merges multi-value headers**: `HTTPURLResponse` merges multiple headers with the same name (especially `Set-Cookie`) into a single string → a cookie-parsing interceptor may parse this incorrectly. Android returns the correct list.
- **iOS `followRedirects=false` is best-effort**: URLSession still follows redirects by default.

**C. The `http` package path and `verifyPin`**: leaf-only, not a strong security guarantee — **do not use them for sensitive data** (see the warnings in [4.3](#43-integrating-with-the-http-package) and [4.5](#45-manual-verification)).

#### Quick recommendations

- For sensitive data → **Dio + `createDioAdapter()`**, pinning the **intermediate + a backup**.
- Don't rely on `createIOClient`/`verifyPin` as the primary security layer.

---

## 5. Malware — On-Device Threat Scanning

The malware module scans the device for threats: it inspects installed apps (and, when storage permission is granted, files on disk) and classifies findings into categories such as virus, blacklist, accessibility abuse, suspicious, and untrusted.

> ⚠️ **Android only.** The scanner is backed by the Android native SDK. On iOS these APIs are **not** available (the plugin exposes no malware channel) — guard every call with `Platform.isAndroid`, or the method channel throws `CShieldException(nativeError)`.

All methods live on `CShieldMalware`:

```dart
import 'dart:io' show Platform;
import 'package:c_shield_embedded/c_shield_embedded.dart';

if (Platform.isAndroid) {
  final result = await CShieldMalware.scanDevice();
}
```

### 5.1 Permissions (Android)

Scanning **installed apps** requires no storage permission. Scanning **files** does — declare the storage permissions in `android/app/src/main/AndroidManifest.xml`:

```xml
<!-- Android ≤ 10 -->
<uses-permission android:name="android.permission.READ_EXTERNAL_STORAGE" />

<!-- Android 11+ : full-disk file scanning -->
<uses-permission
    android:name="android.permission.MANAGE_EXTERNAL_STORAGE"
    tools:ignore="AllFilesAccessPolicy,ScopedStorage" />
```

> The SDK does **not** request permissions itself — the host app is responsible for requesting them at runtime (e.g. via the `permission_handler` package). `MANAGE_EXTERNAL_STORAGE` (All files access) is a special permission granted from system Settings, not a normal runtime dialog.

When storage access is missing, `scanDevice()` still completes but only covers installed apps; the returned `DeviceScanResult.storagePermissionGranted` is `false` and `totalFiles` reflects the reduced coverage.

### 5.2 Scanning the whole device

`scanDevice()` runs a full scan and completes with a categorized `DeviceScanResult`. The scan runs natively and may take a while; call `stopScan()` to request cancellation (best-effort — the in-flight `scanDevice()` future still resolves on its own).

```dart
try {
  final result = await CShieldMalware.scanDevice();

  final threats = result.virus.length +
      result.blacklist.length +
      result.accessibility.length +
      result.suspicious.length +
      result.untrusted.length;

  if (threats == 0) {
    print('Device clean — scanned ${result.totalApps} apps, ${result.totalFiles} files');
  } else {
    for (final pkg in result.virus) {
      print('Virus: ${pkg.name ?? pkg.packageName} (${pkg.source})');
    }
  }
} on CShieldException catch (e) {
  print('Scan failed: [${e.code.name}] ${e.message}');
}

// Cancel an in-flight scan (e.g. the user navigated away)
await CShieldMalware.stopScan();
```

### 5.3 Analyzing a single app or APK file

Instead of a full scan, analyze one target and get a single `ScannedPackage`:

```dart
// An installed app, by package name
final app = await CShieldMalware.analyzeInstalledApp('com.example.target');

// An APK file on disk, by absolute path
final apk = await CShieldMalware.analyzeApkFile('/storage/emulated/0/Download/app.apk');

print('${apk.packageName} — trust: ${apk.trustType}, source: ${apk.source}');
```

Both throw `CShieldException(invalidArgument)` if the path/package name is missing, and `CShieldException(nativeError)` on a native failure.

### 5.4 Result models

**`DeviceScanResult`:**

| Field | Type | Description |
|---|---|---|
| `totalApps` | `int` | Number of installed apps scanned |
| `totalFiles` | `int` | Number of files scanned (0 without storage permission) |
| `startedAtMillis` | `int` | Scan start time (epoch ms) |
| `durationMillis` | `int` | Total scan duration in ms |
| `storagePermissionGranted` | `bool` | Whether file scanning had storage access |
| `virus` | `List<ScannedPackage>` | Detected malware |
| `blacklist` | `List<ScannedPackage>` | Packages matching the known-bad blacklist |
| `accessibility` | `List<ScannedPackage>` | Apps abusing Accessibility services |
| `suspicious` | `List<ScannedPackage>` | Packages flagged as suspicious |
| `untrusted` | `List<ScannedPackage>` | Packages from an untrusted source |

**`ScannedPackage`:**

| Field | Type | Description |
|---|---|---|
| `packageName` | `String` | Application package id |
| `name` | `String?` | Display name, if resolved |
| `sign` | `String?` | Signing certificate signature |
| `fileHash` | `String?` | Hash of the APK/file |
| `urlLocal` | `String?` | Local path of the analyzed file |
| `permissions` | `List<String>` | Declared permissions |
| `trustType` | `String?` | Trust classification |
| `source` | `String` | Where the package came from |
| `publisher` | `String?` | Publisher, if known |
| `payload` | `String?` | Extra native payload data |

### 5.5 API reference

| Method | Platform | Description |
|---|---|---|
| `scanDevice()` | Android | Full device scan → `DeviceScanResult` |
| `analyzeInstalledApp(packageName)` | Android | Analyze one installed app → `ScannedPackage` |
| `analyzeApkFile(filePath)` | Android | Analyze an APK file on disk → `ScannedPackage` |
| `stopScan()` | Android | Best-effort cancel of the in-flight `scanDevice()` |

---

## 6. Exceptions

All errors from the SDK are thrown as `CShieldException`:

```dart
class CShieldException implements Exception {
  final CShieldErrorCode code;    // error code enum
  final String message;           // error description
  final Object? nativeCause;      // underlying native error, if any
}
```

**`CShieldErrorCode`:**

| Code | Cause |
|---|---|
| `aipMissingHeader` | Response is missing the `cs-timestamp` or `cs-signature` header |
| `aipTimestampExpired` | Timestamp falls outside the ±30 second window |
| `aipInvalidSignature` | The response signature is invalid (response was tampered with) |
| `aipSigningFailed` | Failed to sign the request (private key not ready) |
| `aipDetectProxyCA` | Proxy CA detected — AIP refuses to process |
| `sslNotConfigured` | `createHttpClient()`/`createIOClient()`/`createDioAdapter()` was called before `CShieldSSL.configure()` |
| `sslPinMismatch` | The server's certificate doesn't match the configured pin |
| `notInitialized` | An API was called before `CShieldEmbedded.initialize()` |
| `invalidArgument` | An invalid argument was provided |
| `nativeError` | An unspecified error from the native SDK |

**Catching errors:**

```dart
try {
  final response = await client.post(Uri.parse('https://api.example.com/login'), ...);
} on CShieldException catch (e) {
  switch (e.code) {
    case CShieldErrorCode.aipTimestampExpired:
      // Clock skew or a replay attack
      _showError('Time verification error');
      break;
    case CShieldErrorCode.aipInvalidSignature:
      // Response was tampered with
      _logSecurityEvent('Response tampered');
      break;
    case CShieldErrorCode.sslPinMismatch:
      // Certificate mismatch — MITM or the pin needs rotating
      _logSecurityEvent('SSL pin mismatch');
      break;
    default:
      _showError('Security error: ${e.message}');
  }
}
```

---

## Typical Integration Flow

```
main()
  +-- WidgetsFlutterBinding.ensureInitialized()
  +-- CShieldEmbedded.initialize()              // required — before runApp()
  +-- CShieldSSL.configure(pins, host)          // if using certificate pinning
  +-- runApp()

Initialize the HTTP client (singleton)
  +-- CShieldInterceptor(inner: CShieldSSL.createIOClient())   // http package
      // or Dio:
  +-- dio.httpClientAdapter = CShieldSSL.createDioAdapter()
  +-- dio.interceptors.add(CShieldDioInterceptor())
```
