// SAMPLE: Anti-overlay (tapjacking guard). Android only.
//
// Scenario: a sensitive screen must not accept taps while another app draws a
// window over it.
//
// You need: `protect()` when the screen appears, `unprotect()` when it goes
// away, and a listener on `CShieldEmbedded.events` to warn the user.
//
// Guide: doc/anti-overlay.md.

import 'dart:async';

import 'package:c_shield_embedded/c_shield_embedded.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

class AntiOverlaySample extends StatefulWidget {
  const AntiOverlaySample({super.key});

  @override
  State<AntiOverlaySample> createState() => _AntiOverlaySampleState();
}

class _AntiOverlaySampleState extends State<AntiOverlaySample> {
  // The guard exists on Android only; on iOS the calls are not implemented.
  static final _supported = defaultTargetPlatform == TargetPlatform.android;

  StreamSubscription<CShieldEvent>? _sub;
  String? _warning;
  int _taps = 0;

  @override
  void initState() {
    super.initState();
    if (!_supported) return;

    // Default: taps on a fully obscured window are swallowed. Pass
    // `blockObscuredTouches: false` to observe without blocking.
    CShieldAntiOverlay.protect();

    _sub = CShieldEmbedded.events.listen((event) {
      switch (event) {
        case OverlayDetected(:final fullyObscured):
          setState(() => _warning = fullyObscured
              ? 'Another app is covering this screen. Taps are blocked.'
              : 'Another app is partly covering this screen.');
        case OverlayCleared():
          setState(() => _warning = null);
        default:
          break; // events of other features
      }
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    if (_supported) CShieldAntiOverlay.unprotect();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Anti-overlay')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text(
              'This screen is protected while it is open. Draw another app over it '
              '(a chat bubble, a screen filter) and tap: the tap is swallowed and a warning appears.'),
          const SizedBox(height: 16),
          if (!_supported) const Text('Android only.'),
          if (_warning != null)
            Text(_warning!,
                style: const TextStyle(
                    color: Colors.deepOrange, fontWeight: FontWeight.bold)),
          FilledButton(
              onPressed: () => setState(() => _taps++),
              child: Text('Confirm transfer (taps: $_taps)')),
        ],
      ),
    );
  }
}
