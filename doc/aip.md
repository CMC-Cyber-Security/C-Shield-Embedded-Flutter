# AIP - API Integrity Protection

AIP signs every request your app sends and verifies the signature of every response it receives.
A request that was forged, replayed, or modified in transit is rejected by your server; a response
that was tampered with is rejected by the app.

**Platforms:** Android and iOS.

This page is a guide. Do Steps 1, 2 and 4 in every app. Do Step 3 only if your server demands a
higher trust level on some routes.

| | Step | What you do | Runnable sample |
|---|---|---|---|
| 1 | [Sign every request](#step-1-sign-every-request) | Add one interceptor to your HTTP client | [basic_dio.dart](../example/lib/samples/basic_dio.dart), [basic_http.dart](../example/lib/samples/basic_http.dart) |
| 2 | [Wait for the SDK at app start](#step-2-wait-for-the-sdk-at-app-start) | Add one `await` to your splash screen | [startup_readiness.dart](../example/lib/samples/startup_readiness.dart) |
| 3 | [Sensitive routes](#step-3-sensitive-routes) (optional) | Raise the trust level before payment-like calls | [sensitive_flow.dart](../example/lib/samples/sensitive_flow.dart) |
| 4 | [Show errors to the user](#step-4-show-errors-to-the-user) | Add one `catch` pattern | [error_handling.dart](../example/lib/samples/error_handling.dart) |

Special cases, only if they apply to you:
[signing only some requests](#signing-only-some-requests) ·
[manual signing](#advanced-manual-signing)

Every snippet below comes from a sample in [`example/lib/samples/`](../example/lib/samples). Each
sample is one self-contained file: you can read it top to bottom without opening another one. See
[Running the samples](#running-the-samples).

---

## Before you start

- The native SDKs are added to the host app:
  [Android](android-host-app-integration.md), [iOS](ios-host-app-integration.md).
- `CShieldEmbedded.initialize()` is called in `main()` before `runApp()`, as in the
  [README quick start](../README.md#quick-start) and
  [`example/lib/main.dart`](../example/lib/main.dart).
- You test on a **physical device**. An emulator or Simulator cannot attest, so it can never sign a
  request. See [trust levels](attestation.md#trust-levels).

One idea is enough to follow this guide: `initialize()` starts **attestation** in the background.
Attestation gives the device a signing key, an access token, and a **trust level** (L3 on a typical
device). Requests can be signed once it has finished.

---

## Step 1: Sign every request

Add the interceptor once, where you create your HTTP client. After that, API calls look exactly
like normal calls.

### Dio

Recommended.

```dart
Dio buildProtectedDio() {
  final dio = Dio(BaseOptions(baseUrl: 'https://api.example.com'));

  // TLS pinning (optional but recommended; see ssl-pinning.md).
  dio.httpClientAdapter = CShieldSSL.createDioAdapter();

  // Signs every request and verifies every response.
  dio.interceptors.add(CShieldDioInterceptor(dio: dio));

  return dio;
}
```

Always pass the same instance as `dio:`. The interceptor resends a request through it after
refreshing an expired token; without it, nothing is retried.

Sample: [basic_dio.dart](../example/lib/samples/basic_dio.dart)

### http package

`CShieldInterceptor` is an `http.Client`. Use it wherever you use `http.Client`:

```dart
http.Client buildProtectedClient() {
  return CShieldInterceptor(
    // The inner client does the pinning; leave it out to sign without pinning.
    inner: CShieldSSL.createIOClient(),
  );
}
```

Signing and verification are identical to Dio. Pinning on this path is weaker (leaf certificate
only), so prefer Dio for sensitive APIs. See [ssl-pinning.md](ssl-pinning.md#which-path-to-use).

Sample: [basic_http.dart](../example/lib/samples/basic_http.dart)

**Done when:** a call to a protected endpoint succeeds on a real device. If it fails, the error
tells you why: see [Step 4](#step-4-show-errors-to-the-user).

---

## Step 2: Wait for the SDK at app start

**The problem.** `initialize()` returns immediately, but the SDK is not able to sign requests yet.
It first has to attest the device with the C-Shield server, which typically takes a second or two
on first launch (longer on a slow network):

```
initialize() returns ──► SDK is attesting the device ──► ready
                         a request sent here is refused
```

A request sent during that window is **not sent**: the interceptor throws
`CShieldException(notReady)`. In practice this hits whatever your app calls first, such as an
auto-login or a config fetch on launch.

**The fix.** Wait on your splash screen (or first screen) until the SDK is ready:

```dart
// After initialize(), before navigating away from the splash screen.
final state = await CShieldAttest.awaitReady(timeoutMs: 8000);
switch (state) {
  case CShieldState.ready:
  case CShieldState.degraded:
    goHome();
  case CShieldState.initializing:
    showRetryButton();
  case CShieldState.unavailable:
    showDeviceNotSupported(await CShieldAttest.lastError());
}
```

`awaitReady` does not start anything. It waits for the work `initialize()` already started and
returns at once if that has finished, so it costs nothing on later launches.

| It returns | Meaning | What to do |
|---|---|---|
| `ready` | Requests can be signed | Continue into the app |
| `degraded` | Requests can be signed, but the device has a low trust level. The server decides which routes to allow | Continue into the app |
| `initializing` | The timeout passed and the SDK is still working (slow or no network) | Show "retry" and call `awaitReady` again |
| `unavailable` | This device or build can never be attested. `lastError()` gives the reason | Tell the user. Do not retry |

That is all for this step.

Sample: [startup_readiness.dart](../example/lib/samples/startup_readiness.dart). Concepts:
[attestation.md](attestation.md#readiness).

### If your app cannot wait at startup

Skip this unless you have no splash screen, or requests can start from places that cannot wait.

The interceptor has a setting named `onNotReady`. It answers one question: **what should happen to
a request that arrives while the SDK is still not ready?**

| `onNotReady:` | What happens to that request | Use it when |
|---|---|---|
| `OnNotReady.failFast` (default) | It is not sent. `CShieldException(notReady)` is thrown | You wait at startup as shown above, so this is only a safety net |
| `OnNotReady.blockRetry` | It is held for up to 2 seconds until the SDK is ready, then signed and sent. If the SDK is still not ready, it fails like `failFast` | You cannot wait at startup |
| `OnNotReady.passThrough` | It is sent **without a signature**, and its response is not verified | Only for endpoints your server does not protect. A protected endpoint rejects an unsigned request |

```dart
dio.interceptors.add(CShieldDioInterceptor(dio: dio, onNotReady: OnNotReady.blockRetry));
```

When a request does fail with `notReady`, check `retryable` on the exception: `true` means the SDK
is still starting (ask the user to try again); `false` means the device is not supported.

---

## Step 3: Sensitive routes

**Skip this step** unless your server sets a minimum trust level (or a maximum trust age) on some
routes, such as payment, transfer or login. Ask your backend team if you are not sure.

**The problem.** Every attested device has a trust level, and a typical device sits at **L3**. A
route that demands **L4** answers `403 CSHIELD_DEVICE_NOT_ALLOWED` until the app raises the device's
trust. Raising trust runs a stronger check (Play Integrity on Android, one quota unit per run), so
the SDK does it only when you ask.

**The fix.** Call `ensureTrust` right before the sensitive call:

```dart
Future<void> pay() async {
  final result = await CShieldAttest.ensureTrust(TrustLevel.l4, timeoutMs: 20000);
  if (result != EnsureTrustResult.satisfied) {
    showCannotContinue(result); // see the table below
    return;
  }
  await dio.post('/payment'); // an ordinary call, signed by the interceptor
}
```

| Result | Meaning | What to do |
|---|---|---|
| `satisfied` | The device is at the level | Continue |
| `insufficient` | The device tried and cannot reach the level | Block, or offer a reduced feature |
| `offline` | No connection. Not a verdict on the device | Let the user retry |
| `rateLimited`, `timeout` | Temporary. The current trust level is not lowered | Retry later |
| `unavailable` | The device can never be attested | Do not retry |

When the device is already at the level, the call returns `satisfied` immediately and costs
nothing, so it is safe to call every time.

**If the route also has a maximum trust age** (the server answers `403 CSHIELD_TRUST_NOT_FRESH`),
add `requireFresh: true`. This always runs the stronger check:

```dart
await CShieldAttest.ensureTrust(TrustLevel.l4, requireFresh: true, timeoutMs: 20000);
```

Sample: [sensitive_flow.dart](../example/lib/samples/sensitive_flow.dart)

### Alternative: let the interceptor raise trust

Use this instead of `ensureTrust` if you would rather not add code to each screen. You map routes
to levels once, where the client is built:

```dart
dio.interceptors.add(CShieldDioInterceptor(
  dio: dio, // required: the interceptor resends through it
  requiredLevel: (options) => switch (options.uri.path) {
    '/payment' || '/transfer' => TrustLevel.l4,
    _ => null, // ordinary routes: nothing extra
  },
));
```

For a mapped route the interceptor sends the request as usual. If the server answers with one of
the two trust `403`s, it raises trust and resends the request once. Your screens make plain calls.

The trade-off: nothing is checked before the request. A device that cannot reach the level finds
out from the server's `403`, after the user has already submitted. With `ensureTrust` you can stop
them before they start.

Sample: [required_level.dart](../example/lib/samples/required_level.dart)

### Limits to know

- **Android without Play Integrity:** if `initialize()` got no `cloudProjectNumber`, trust cannot be
  raised. `ensureTrust` and the `requiredLevel` retry throw
  `CShieldException(playIntegrityNotConfigured)`. See
  [attestation.md](attestation.md#running-without-play-integrity-android).
- **iOS:** the highest level is L4, and a debug build is capped lower. See
  [trust levels](attestation.md#trust-levels) before testing an L4 route on iOS.

---

## Step 4: Show errors to the user

Two different things can go wrong, and they arrive in different shapes:

| What happened | Dio | `http` |
|---|---|---|
| **The SDK refused** (not ready, pin mismatch, tampered response) | `DioException` whose `error` is a `CShieldException` | `CShieldException` thrown directly |
| **The server refused** (trust too low, token rejected) | `DioException` with a response: status `401` / `403` and a `code` in the JSON body | A normal response with status `401` / `403` |

```dart
try {
  await dio.post('/transfer');
} on DioException catch (e) {
  final sdkError = e.error;
  if (sdkError is CShieldException) {
    show(messageFor(sdkError));          // the SDK refused
  } else {
    show(serverCode(e));                 // the server refused, e.g. CSHIELD_DEVICE_NOT_ALLOWED
  }
}
```

A ready-made `messageFor()` that maps every `CShieldErrorCode` to a user-facing message, and a
`serverCode()` that reads the server's code, are in
[error_handling.dart](../example/lib/samples/error_handling.dart); copy them and adjust the wording.

The codes you will meet most often:

| Code | Tell the user | Retry? |
|---|---|---|
| `notReady` with `retryable == true` | Security is still starting up, try again | Yes |
| `notReady` with `retryable == false` | This device is not supported | No |
| `sslPinMismatch`, `aipInvalidSignature`, `aipMissingHeader`, `aipDetectProxyCA` | The connection could not be verified | No. Never fall back to an unprotected call |
| `aipTimestampExpired` | Check the date and time on the device | After fixing the clock |

> With response verification on, the Dio interceptor reads the response as raw bytes. On a **failed**
> request, `e.response.data` can therefore be a `List<int>`; decode it before reading the server's
> `code`. `serverCode()` in the sample shows how.

Sample: [error_handling.dart](../example/lib/samples/error_handling.dart). Full list:
[events-and-errors.md](events-and-errors.md).

---

## Signing only some requests

When the same client also talks to endpoints your server does not protect (public config, a
third-party API), pass a `signWhen` predicate. A request it rejects is sent unsigned and its
response is not verified.

```dart
bool isProtected(RequestOptions options) {
  const protectedPaths = {'/verify-otp', '/payment', '/transfer'};
  return protectedPaths.contains(options.uri.path);
}

dio.interceptors.add(CShieldDioInterceptor(dio: dio, signWhen: isProtected));
```

Sample: [selective_signing.dart](../example/lib/samples/selective_signing.dart)

---

## What the interceptors do for you

You do not write code for any of this.

| Server response | Interceptor action |
|---|---|
| `401 CSHIELD_INVALID_ACCESS_TOKEN` | Refreshes the token and resends once |
| `403 CSHIELD_DEVICE_NOT_ALLOWED` / `CSHIELD_TRUST_NOT_FRESH` | Only when `requiredLevel` returns a level: raises trust and resends once |
| Any other `401` / `403` | Not retried; returned to your code |

Each retry happens at most once per request.

- **Dio:** retries require the `dio:` argument.
- **`http`:** retries work for `http.Request` only. A `MultipartRequest` cannot be replayed, so its
  `401` / `403` is returned as is.

Multipart bodies (Dio `FormData`, `http.MultipartRequest`) are signed automatically.

### Interceptor options

Both interceptors take the same options. The callbacks receive `RequestOptions` on Dio and
`http.BaseRequest` on `http`.

| Option | Default | Description | Covered in |
|---|---|---|---|
| `dio` (Dio only) | `null` | The `Dio` this interceptor is added to. Enables automatic retries | [Step 1](#step-1-sign-every-request) |
| `inner` (`http` only) | `http.Client()` | The client that actually sends the request | [Step 1](#http-package) |
| `onNotReady` | `failFast` | What to do when attestation is not ready at signing time | [Step 2](#step-2-wait-for-the-sdk-at-app-start) |
| `requiredLevel` | `null` | Minimum trust level for a request; the interceptor raises trust for it | [Step 3](#alternative-let-the-interceptor-raise-trust) |
| `signWhen` | `null` (sign all) | Return `true` for requests to sign | [Signing only some requests](#signing-only-some-requests) |
| `verifyResponses` | `true` | Verify response signatures. Set `false` only if the server does not sign responses | |

---

## Advanced: manual signing

Only for an HTTP client the SDK has no interceptor for. Prefer the interceptors whenever they fit:
the function below is roughly what they do for you.

```dart
Future<http.Response> signedPost(http.Client client, Uri uri, Map<String, dynamic> json,
    {bool isRetry = false}) async {
  final body = Uint8List.fromList(utf8.encode(jsonEncode(json)));

  // 1. Sign. The proof is single-use and valid for 30 seconds: never cache or reuse it.
  final proofHeaders = await CShieldAIP.signRequest(
    method: 'POST',
    path: uri.path,
    query: uri.query, // '' when there is no query string
    body: body,
    contentType: 'application/json',
  );

  // 2. Send exactly the bytes that were signed.
  final response = await client.post(uri,
      headers: {'Content-Type': 'application/json', ...proofHeaders}, body: body);

  // 3. Verify with the same path and query that were signed. Throws CShieldException on failure.
  await CShieldAIP.verifyResponse(
    statusCode: response.statusCode,
    path: uri.path,
    query: uri.query,
    headers: response.headers,
    body: response.bodyBytes, // raw bytes, not decoded
  );

  // 4. Token expired on the server: refresh it and resend once.
  if (!isRetry &&
      CShieldAIP.isInvalidAccessToken(response.statusCode, response.bodyBytes) &&
      await CShieldAttest.forceRefresh()) {
    return signedPost(client, uri, json, isRetry: true);
  }
  return response;
}
```

Pass `verifyResponse` the same `path` and `query` you signed with. Do not recompute them from a
later URL: a followed redirect would change them.

Sample: [manual_signing.dart](../example/lib/samples/manual_signing.dart). Wire format:
[signing-protocol.md](signing-protocol.md).

### CShieldAIP API

| Method | Description |
|---|---|
| `signRequest({method, path, query, body, contentType})` | Signs a request. Returns `{'cs-proof': ...}`. Throws `CShieldException(notReady)` if attestation is not ready |
| `verifyResponse({statusCode, path, query, headers, body})` | Verifies a response signature. Throws `CShieldException` on failure |
| `verify({payload, signature})` | Verifies a signature over a payload string you built yourself |
| `normalizeBody({body, contentType})` | Returns `{'normalizedString', 'sizeInBytes', 'hash'}` for a body |
| `isInvalidAccessToken(statusCode, body)` | `true` for a `401` carrying `CSHIELD_INVALID_ACCESS_TOKEN` |
| `forceRefresh({timeoutMs = 5000})` | Refreshes the access token now. Returns `true` when a new token is ready |

---

## Running the samples

The [example app](../example) is a menu with one screen per sample. Each sample is a single file
that imports nothing from the other samples. It starts with a comment describing the scenario, then
the code to copy (top-level functions), then a small screen built from plain Flutter widgets.

```bash
cd example
flutter run                                        # on a physical device
flutter run --dart-define=NO_PLAY_INTEGRITY=true   # Android: start without cloudProjectNumber
```

The samples call a demo server with three routes: `POST /verify-otp` (any trust level),
`POST /payment` (L4) and `POST /transfer` (L4 with fresh proof).

---

## Errors

| Code | Cause |
|---|---|
| `notReady` | Attestation not ready at signing time. Check `retryable` |
| `aipSigningFailed` | The request could not be signed, for example a malformed query string |
| `aipMissingHeader` | A `2xx` response has no signature headers |
| `aipTimestampExpired` | Response timestamp outside the ±30 second window: clock skew or a replay |
| `aipInvalidSignature` | Response signature does not match: the response was tampered with |
| `aipDetectProxyCA` | A proxy CA was detected; AIP refuses to proceed |

See [events-and-errors.md](events-and-errors.md) for the full list.
