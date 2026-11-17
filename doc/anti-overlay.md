# Anti-Overlay — Tapjacking Guard

A runtime guard for your app's own sensitive screens (login, OTP, money transfer). It defends
against overlay and tapjacking attacks, where a malicious app draws a fake or transparent window on
top of your screen to hijack taps or trick the user.

**Platforms:** Android only. The guard relies on Android's obscured-window touch flags, which have
no iOS equivalent. On iOS the calls are not implemented, so guard them with `Platform.isAndroid`.

---

## How it works

The guard wraps the current Activity's window and checks every touch for Android's
`FLAG_WINDOW_IS_OBSCURED` and `FLAG_WINDOW_IS_PARTIALLY_OBSCURED` flags. The framework sets these
itself, so another app cannot fake them.

- Taps that arrive while the window is **fully obscured** are swallowed, so the overlay cannot
  harvest them.
- Your app is notified so it can warn the user or pause input.

It is opt-in **per screen**. Hooking every screen would raise false alarms from legitimate floating
windows such as chat bubbles.

---

## Protecting a screen

Call `protect()` when the sensitive screen appears and `unprotect()` when you leave it:

```dart
import 'dart:io' show Platform;

import 'package:c_shield_embedded/c_shield_embedded.dart';
import 'package:flutter/material.dart';

class _LoginPageState extends State<LoginPage> {
  @override
  void initState() {
    super.initState();
    if (Platform.isAndroid) {
      CShieldAntiOverlay.protect();
    }
  }

  @override
  void dispose() {
    if (Platform.isAndroid) {
      CShieldAntiOverlay.unprotect();
    }
    super.dispose();
  }

  // build() ...
}
```

To observe only, delivering obscured taps normally while still receiving events:

```dart
await CShieldAntiOverlay.protect(blockObscuredTouches: false);
```

---

## Reacting to overlay events

Events arrive on the shared `CShieldEmbedded.events` stream:

```dart
late final StreamSubscription<CShieldEvent> _sub;

@override
void initState() {
  super.initState();
  _sub = CShieldEmbedded.events.listen((event) {
    switch (event) {
      case OverlayDetected(:final fullyObscured):
        _showOverlayWarning(fully: fullyObscured);
      case OverlayCleared():
        _hideOverlayWarning();
      default:
        break; // events from other features
    }
  });
}

@override
void dispose() {
  _sub.cancel();
  super.dispose();
}
```

| Event | Fields | Meaning |
|---|---|---|
| `OverlayDetected` | `fullyObscured` | Another window completely covers the touched view. The strongest signal |
| | `partiallyObscured` | Another window covers part of the screen (Android 10+). Weaker; some OEM system UI triggers it |
| `OverlayCleared` | — | Fires once when touches are no longer obscured |

---

## API reference

All methods are static on `CShieldAntiOverlay`.

| Method | Description |
|---|---|
| `protect({blockObscuredTouches = true})` | Guards the current screen. Swallows fully obscured taps when `blockObscuredTouches` is `true` |
| `unprotect()` | Removes the guard and restores normal touch handling |

## Related

- [malware.md](malware.md): `DeviceScanResult.overlay` lists the installed apps that *could* draw
  an overlay. This guard blocks one at the moment it happens.
- [behavioral-touch-guard.md](behavioral-touch-guard.md) can protect the same screen. When you use
  both, call the `unprotect()` methods in the reverse order of the `protect()` calls.
