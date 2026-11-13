# SSL — Certificate Pinning

Certificate pinning makes the app accept only the server certificates you expect. It stops a
man-in-the-middle even when the device trusts a rogue CA, such as one a user installed for a proxy
tool.

**Platforms:** Android and iOS.

- [Which path to use](#which-path-to-use)
- [Getting pin values](#getting-pin-values)
- [Configuring pins](#configuring-pins)
- [Dio](#dio)
- [http package](#http-package)
- [Manual verification](#manual-verification)
- [Limitations](#limitations)
- [API reference](#api-reference)

---

## Which path to use

`dart:io` exposes only the leaf certificate of a TLS connection, so pure-Dart pinning can never see
the rest of the chain. The SDK works around this on the Dio path by performing the request natively
(OkHttp on Android, URLSession on iOS), where the whole chain is visible.

| Capability | `createDioAdapter` (Dio) | `createIOClient` (`http`) | `verifyPin` |
|---|:---:|:---:|:---:|
| Matches pins against the whole chain | ✅ | ❌ leaf only | ❌ leaf only |
| Intermediate pin survives leaf rotation | ✅ | ❌ | ❌ |
| System CA validation, fail-closed | ✅ | partial¹ | partial |
| Blocks user-installed CAs (Burp, Charles) | ✅ | ❌² | — |

¹ `badCertificateCallback` runs only when default validation fails.
² A MITM certificate that chains to a CA the device trusts passes without the pin being checked.

**For sensitive data, use Dio with `createDioAdapter()`.** Do not rely on `createIOClient` or
`verifyPin` as your primary protection.

---

## Getting pin values

A pin is the SHA-256 hash of a certificate's SPKI (Subject Public Key Info), base64-encoded and
prefixed with `sha256/`.

Leaf pin, straight from the server:

```bash
openssl s_client -connect api.example.com:443 -servername api.example.com 2>/dev/null \
  | openssl x509 -pubkey -noout \
  | openssl pkey -pubin -outform DER \
  | openssl dgst -sha256 -binary \
  | openssl base64

# Prefix the output with "sha256/", for example:
# sha256/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=
```

### Pin the intermediate CA to survive rotation

Leaf certificates are reissued often (about every 90 days with Let's Encrypt or Google Trust
Services) and may get a new key each time. A leaf-only pin then goes stale and **the app cannot
connect until you ship an update**.

Pin the public key of a stable intermediate CA instead of, or alongside, the leaf. The Dio adapter
matches against the whole chain, so one matching certificate anywhere in it is enough.

```bash
# Print the full chain
openssl s_client -connect api.example.com:443 -servername api.example.com -showcerts </dev/null 2>/dev/null

# Save an intermediate "BEGIN CERTIFICATE" block to intermediate.pem, then:
openssl x509 -in intermediate.pem -pubkey -noout \
  | openssl pkey -pubin -outform DER \
  | openssl dgst -sha256 -binary | openssl base64
```

**Always configure at least two pins** (primary and backup) so a rotation cannot lock users out.

> Intermediate pins work only on the Dio path. The `http` path and `verifyPin` compare the leaf
> only.

---

## Configuring pins

Call `configureHosts` after `initialize()` and before the first network request. Declare **every**
pinned host in this single call:

```dart
await CShieldEmbedded.initialize(license: 'your_c_shield_license');

await CShieldSSL.configureHosts(pinsByHost: {
  'api.example.com':   ['sha256/<intermediate>', 'sha256/<backup>'],
  '*.cdn.example.com': ['sha256/<...>', 'sha256/<backup>'], // exactly one subdomain level
  '**.example.org':    ['sha256/<...>', 'sha256/<backup>'], // the apex and any subdomain depth
});
```

For a single host, `configure` is a shortcut:

```dart
await CShieldSSL.configure(
  pins: ['sha256/<intermediate>', 'sha256/<backup>'],
  hostname: 'api.example.com',
);
```

Rules:

- If several patterns match a host, the host accepts the pins of all of them.
- Hosts that are not configured use normal system CA validation.
- Pins that match the **root CA** are ignored. Pin the leaf or an intermediate.
- Host names are matched case-insensitively.

### The pin set is sealed after configuration

By default (`allowRuntimeUpdates: false`) the native pin set is locked once configuration succeeds.
This is why all hosts must be declared in one call. A later `updatePins` throws
`CShieldException(sslNotConfigured)`.

To rotate pins at runtime, opt in when you configure. This is less strict, so use it only if you
have a secure channel for delivering new pins:

```dart
await CShieldSSL.configureHosts(
  pinsByHost: {'api.example.com': ['sha256/<...>', 'sha256/<backup>']},
  allowRuntimeUpdates: true,
);

// later
await CShieldSSL.updatePins(
  pins: ['sha256/<new>', 'sha256/<backup>'],
  hostname: 'api.example.com',
);
```

Calling `configureHosts` again when pinning is already configured is safe: the SDK keeps the native
configuration as it is and does not throw. This covers a Dart isolate restarting inside a process
that is still alive.

---

## Dio

```dart
import 'package:c_shield_embedded/c_shield_embedded.dart';
import 'package:dio/dio.dart';

final dio = Dio(BaseOptions(baseUrl: 'https://api.example.com'));

dio.httpClientAdapter = CShieldSSL.createDioAdapter();

// Usually combined with AIP:
dio.interceptors.add(CShieldDioInterceptor(dio: dio));
```

HTTPS requests to a configured host are performed natively with pinning enforced. Everything else
goes through Dio's standard adapter, unaffected.

Create the adapter after `configureHosts`; before that it throws
`CShieldException(sslNotConfigured)`.

---

## http package

> **Not recommended for sensitive APIs.** See [Which path to use](#which-path-to-use).

```dart
import 'package:c_shield_embedded/c_shield_embedded.dart';

// Create once and reuse.
final client = CShieldSSL.createIOClient();

final response = await client.get(Uri.parse('https://api.example.com/data'));
```

Combined with AIP:

```dart
final client = CShieldInterceptor(inner: CShieldSSL.createIOClient());
```

`createHttpClient()` returns the underlying `dart:io` `HttpClient` if you need it for another
library.

---

## Manual verification

`verifyPin()` checks one certificate against the configured pins. Use it where neither client fits,
for example a WebSocket:

```dart
final trusted = await CShieldSSL.verifyPin(
  certDerBase64: base64.encode(peerCertificateDerBytes),
  host: 'api.example.com',
);

if (!trusted) {
  throw const CShieldException(
    CShieldErrorCode.sslPinMismatch,
    'Certificate pin mismatch for api.example.com',
  );
}
```

Dart can only hand over the leaf certificate, so intermediate pins do not match here. Treat it as a
secondary check.

---

## Limitations

**Inherent to Flutter**

- **Coverage is narrow.** Only traffic through the Dio instance that has the adapter, and only to
  configured hosts, is pinned. WebViews (`webview_flutter`), image loading (`Image.network`,
  `CachedNetworkImage`), other HTTP libraries, and third-party plugins are **not** covered. Route
  sensitive API calls through the pinned Dio instance.
- **Web builds** cannot pin; browsers do not allow it.
- **Expiry.** A stale pin breaks the app. Pin an intermediate and keep a backup pin.

**From native transport on the Dio path**

- **Buffered, not streaming.** No upload or download progress, no `ResponseType.stream`, no SSE.
  Large files are held in memory. Use a separate, unpinned Dio instance for those cases.
- **`CancelToken` does not stop the native request.** Dio cancels on the Dart side; the native
  request runs to completion.
- **iOS merges repeated headers.** `HTTPURLResponse` joins headers with the same name, notably
  `Set-Cookie`, into one string. A cookie-parsing interceptor may misread it. Android returns the
  proper list.
- **iOS `followRedirects: false` is best effort.** URLSession follows redirects by default.

---

## API reference

All methods are static on `CShieldSSL`.

| Method | Description |
|---|---|
| `configureHosts({pinsByHost, allowRuntimeUpdates = false})` | Configures pinning for one or more host patterns |
| `configure({pins, hostname, allowRuntimeUpdates = false})` | Single-host shortcut for `configureHosts` |
| `updatePins({pins, hostname})` | Replaces a host's pins. Requires `allowRuntimeUpdates: true` at configuration |
| `isConfigured()` | `true` once pinning is configured |
| `createDioAdapter()` | **Recommended.** Dio `HttpClientAdapter` with native, whole-chain pinning |
| `createIOClient()` | `http` package client. Leaf-only, pure Dart |
| `createHttpClient()` | `dart:io` `HttpClient`. Leaf-only, pure Dart |
| `verifyPin({certDerBase64, host})` | Checks one DER certificate against the configured pins |

## Errors

| Code | Cause |
|---|---|
| `invalidArgument` | Empty host map, blank host name, empty pin list, or a pin without the `sha256/` prefix |
| `sslNotConfigured` | A client or adapter was created before configuration, or `updatePins` was called on a sealed pin set |
| `sslPinMismatch` | The server's certificate chain matches none of the configured pins |

See [events-and-errors.md](events-and-errors.md) for the full list.
