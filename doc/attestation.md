# Attestation — Device Trust

Attestation lets a device prove its identity and integrity with its secure hardware. The C-Shield
cloud verifies that proof and issues a short-lived **access token** carrying a **trust level**. Your
server verifies the token offline and enforces a minimum trust level per route.

**Platforms:**

| | Android | iOS |
|---|---|---|
| Hardware proof | Key Attestation (TEE / StrongBox) | App Attest (Secure Enclave) |
| Environment proof | Play Integrity | — |
| Highest trust level | **L5** | **L4** |

Enrollment starts by itself when you call `CShieldEmbedded.initialize()`. The APIs here let the app
find out whether attestation is ready and raise trust before a sensitive flow.

> **Integrating?** Follow the step-by-step guide in [aip.md](aip.md); it tells you which of these
> calls you need and links a runnable sample for each. This page explains the concepts behind them
> and is the reference for `CShieldAttest`.

- [Which call for which situation](#which-call-for-which-situation)
- [Trust levels](#trust-levels)
- [Readiness](#readiness)
- [Raising trust](#raising-trust)
- [Server error codes](#server-error-codes)
- [Running without Play Integrity (Android)](#running-without-play-integrity-android)
- [API reference](#api-reference)

---

## Which call for which situation

| Situation | Use | Guide |
|---|---|---|
| App start | `CShieldEmbedded.initialize()` | [README](../README.md#quick-start) |
| Ordinary API calls | Nothing. The interceptor signs requests and refreshes the token | [Step 1](aip.md#step-1-sign-every-request) |
| Splash screen that waits until the device is ready | `awaitReady()` | [Step 2](aip.md#step-2-wait-for-the-sdk-at-app-start) |
| Status banner or badge | `stateChanges` | [Readiness](#follow-the-state-live) |
| Device unsupported or blocked | `state() == unavailable`, then `lastError()` | [Readiness](#why-it-is-not-ready) |
| A route that needs L4+ | `ensureTrust(TrustLevel.l4)`, or the interceptor's `requiredLevel` | [Step 3](aip.md#step-3-sensitive-routes) |
| A route that also needs fresh proof | `ensureTrust(TrustLevel.l4, requireFresh: true)` | [Step 3](aip.md#step-3-sensitive-routes) |
| Hand-rolled HTTP client, no interceptor | `forceRefresh()` on `401 CSHIELD_INVALID_ACCESS_TOKEN` | [Manual signing](aip.md#advanced-manual-signing) |

---

## Trust levels

A device's trust level reflects how strong its **hardware attestation** is. Level `l0` is never
usable — the server rejects registration there and issues no token — so an **emulator (Android) or
Simulator (iOS) can never attest or sign a request**, because neither produces hardware attestation
the server trusts. With the embedded SDK integrated you must run on a **real device** on both
platforms. The reachable levels differ per platform.

**Android** — requires a real device:

| Scenario | Level |
|---|---|
| StrongBox key with strong Play Integrity | **L5** |
| Hardware-backed key (TEE/StrongBox) with Play Integrity passed | **L4** |
| Hardware-backed key, Play Integrity not run yet / unavailable / unverified — at enrollment, a no-GMS device, or a device that has Google Play but is not certified (e.g. Huawei) | **L3** |
| Only one weak signal (e.g. basic integrity) | **L2** |
| Rooted or bootloader-unlocked device | **L1** |
| **Emulator, software-only keystore, or a spoofed / failed environment** | **L0 — rejected, no token** |

Android reaches up to **L5**. Real devices enroll at **L3** and rise to **L4/L5** once Play Integrity runs.

**iOS** — requires a real device:

| Scenario | Level |
|---|---|
| App Store / TestFlight build, recent App Attest proof | **L4** |
| App Store / TestFlight build, older proof | **L3** |
| Xcode debug / development-signed build on a real iPhone | **L2** |
| **Simulator, or a cloned / failed key** | **L0 / unavailable — rejected, no token** |

iOS reaches up to **L4** (never L5). A **debug build caps at L2**, so an `l3`/`l4` route on iOS needs
a **production-signed** build (App Store / TestFlight) on real hardware.

> **Bottom line: an emulator or Simulator cannot be used with the embedded SDK.** Neither produces the
> hardware attestation the server trusts, so attestation never completes and every protected flow is
> blocked. Test on real hardware — Android with TEE/StrongBox and Google Play certification; iOS with
> a Secure Enclave and a production-signed build.

Compare levels with `atLeast`:

```dart
final level = await CShieldAttest.currentTrustLevel();
if (level.atLeast(TrustLevel.l4)) { /* ... */ }
```

`currentTrustLevel()` is read from the token the device holds and is meant for client-side routing
only, such as hiding a button. The server is what enforces trust. A client cannot forge a higher
level because the token is signed by the C-Shield cloud.

> iOS tops out at **L4**. Setting a route's minimum to L5 on the server blocks every iOS device.

### Cheap by default, expensive on demand

On Android, enrollment and ordinary token refresh run Key Attestation only. That costs no Play
Integrity quota, and most real devices settle at **L3**. Play Integrity runs only when you ask for
more through [`ensureTrust`](#raising-trust), when you ask for fresh proof, or when the keep-trust
window expires.

---

## Readiness

`initialize()` returns immediately and enrollment continues in the background. `CShieldState` tells
you where it stands:

| State | Meaning | Can requests be signed? |
|---|---|---|
| `initializing` | Enrollment or refresh in flight, no usable token yet | Not yet. Wait, or rely on the interceptor's [`onNotReady`](aip.md#step-2-wait-for-the-sdk-at-app-start) policy |
| `ready` | Token and hardware key present | Yes |
| `degraded` | Token and key present, but trust is L0 or L1 | Yes. The **server** decides whether to accept |
| `unavailable` | Permanent failure: blocked, unsupported, or misconfigured | No. **Do not retry** |

`degraded` does not block anything on the client. Only `unavailable` means "cannot work".

### Wait on a splash screen

```dart
switch (await CShieldAttest.awaitReady(timeoutMs: 8000)) {
  case CShieldState.ready:
  case CShieldState.degraded:
    goHome();
  case CShieldState.initializing:
    showRetry('Preparing security…'); // timed out; still working in the background
  case CShieldState.unavailable:
    showUnsupported(await CShieldAttest.lastError());
}
```

`awaitReady` does not start a second attestation. It waits for the one `initialize()` already
started, and returns at once if the state is already `ready` or `unavailable`.

### Follow the state live

```dart
final sub = CShieldAttest.stateChanges.listen((e) {
  debugPrint('attest ${e.state.name} · trust=${e.trustLevel.name} · lastError=${e.lastError}');
});

// in dispose()
await sub.cancel();
```

The stream emits the current state as soon as you subscribe, so there is no need to poll `state()`.

### Why it is not ready

`lastError()` returns the latest stable error code of the enrollment or refresh flow, or `null`:

`device_blocked`, `challenge_rejected`, `attestation_not_enabled`, `device_unsupported`,
`attestation_rejected`, `key_already_bound`, `transport_auth`, `network`, `rate_limited`, …

When the state is `unavailable`, this is the permanent reason. When it is `initializing`, it is the
transient problem the SDK is currently retrying.

---

## Raising trust

Call `ensureTrust` just before a flow whose route requires a higher level than the device has by
default. How to use it, with code: [aip.md, Step 3](aip.md#step-3-sensitive-routes) and
[sensitive_flow.dart](../example/lib/samples/sensitive_flow.dart).

- Already at the level, and `requireFresh` is `false`: returns `satisfied` immediately at no cost.
- Otherwise: the SDK runs the stronger check and refreshes the token. On Android this is a Play
  Integrity request and spends one quota unit.
- `requireFresh: true` always runs the stronger check. Use it for routes where your server sets
  `maxTrustAgeSeconds`: there the level alone is not enough, the proof must also be recent.

| Result | Meaning | What to do |
|---|---|---|
| `satisfied` | Level reached, and fresh if requested | Continue |
| `insufficient` | The device tried and cannot reach the level | Block, or offer a reduced feature |
| `offline` | No connection to the attestation server | Ask the user to check the network and retry. This is not a verdict on the device |
| `rateLimited` | Play Integrity quota or rate limit | Retry later. Current trust is not lowered |
| `timeout` | `timeoutMs` elapsed, or a transient server error | Retry later |
| `unavailable` | Attestation permanently unavailable | Do not retry |

`ensureTrust` and `awaitReady` run on a native background thread, so awaiting them from UI code
does not block the UI.

### ensureTrust or requiredLevel

Instead of calling `ensureTrust` screen by screen, you can map routes to levels with the
interceptor's [`requiredLevel`](aip.md#alternative-let-the-interceptor-raise-trust) option. The two
differ in when the user finds out:

- `ensureTrust` in your flow **blocks before** the user enters the screen. Use it when you want to
  stop an unqualified device early.
- `requiredLevel` **never blocks on the client**. It raises trust in the background and, when the
  server answers with a trust `403`, raises it with fresh proof and resends the request once.

---

## Server error codes

| Server response | Meaning | What the app does |
|---|---|---|
| `403 CSHIELD_DEVICE_NOT_ALLOWED` | Trust is below the route's minimum | `ensureTrust(level)`, then retry |
| `403 CSHIELD_TRUST_NOT_FRESH` | Trust is high enough but the proof is too old | `ensureTrust(level, requireFresh: true)`, then retry |
| `401 CSHIELD_INVALID_ACCESS_TOKEN` | Token expired or rejected | Nothing. The interceptors refresh the token and retry once |

With `requiredLevel` set, the interceptors handle the two `403` cases as well.

---

## Running without Play Integrity (Android)

`cloudProjectNumber` is optional. Leaving it out is a deliberate choice to not use Play Integrity:

```dart
await CShieldEmbedded.initialize(license: 'your_c_shield_license');
```

In that mode, on Android:

- Enrollment and refresh are always Key Attestation only. Play Integrity is never warmed up or
  called.
- Requests are signed as usual and the device gets its hardware-based level, typically **L3**.
- Trust cannot be raised or refreshed. `ensureTrust` throws
  `CShieldException(playIntegrityNotConfigured)`, and so does the interceptor's `403` retry when
  `requiredLevel` is set.

```dart
try {
  await CShieldAttest.ensureTrust(TrustLevel.l4);
} on CShieldException catch (e) {
  if (e.code == CShieldErrorCode.playIntegrityNotConfigured) {
    // Configuration error: pass cloudProjectNumber to initialize() to reach L4+.
  }
}
```

So with Play Integrity off, do not call `ensureTrust` and do not set `requiredLevel`.

`cloudProjectNumber` is a **string of digits**. A non-empty value that is not a positive integer
makes `initialize` fail immediately, which catches typos. iOS ignores the parameter, since App
Attest does not need it.

---

## API reference

All methods are static on `CShieldAttest`.

| API | Returns | Notes |
|---|---|---|
| `state()` | `CShieldState` | Current readiness |
| `awaitReady({timeoutMs = 8000})` | `CShieldState` | Waits for enrollment to settle |
| `stateChanges` | `Stream<AttestStateChanged>` | Emits the current state on subscribe. Carries `state`, `trustLevel`, `lastError` |
| `lastError()` | `String?` | Latest stable error code of enrollment or refresh |
| `currentTrustLevel()` | `TrustLevel` | From the held access token. Client-side routing only |
| `ensureTrust(minLevel, {requireFresh = false, timeoutMs = 15000})` | `EnsureTrustResult` | May spend Play Integrity quota on Android |
| `forceRefresh({timeoutMs = 5000})` | `bool` | Only needed with a hand-rolled HTTP client |

If a platform build does not implement attestation, these calls return the "not available" value
(`CShieldState.unavailable`, `TrustLevel.unknown`, `EnsureTrustResult.unavailable`) instead of
throwing, so the same code runs everywhere.
