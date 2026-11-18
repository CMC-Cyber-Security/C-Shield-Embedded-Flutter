// SAMPLE: Screen capture
//
// Scenario: warn the user while the screen is recorded or mirrored, and black
// out the app in recordings and screenshots.
//
// You need: nothing to turn detection on, it starts in `initialize()`.
// Listen on `CShieldEmbedded.events` for `ScreenCaptureDetected`; the SDK shows
// no warning itself. Call `enableProtection()` once to black out capture; it
// applies to the whole app and cannot be turned off.
//
// Platforms: iOS only.

import 'dart:async';

import 'package:c_shield_embedded/c_shield_embedded.dart';
import 'package:flutter/material.dart';

class ScreenCaptureSample extends StatefulWidget {
  const ScreenCaptureSample({super.key});

  @override
  State<ScreenCaptureSample> createState() => _ScreenCaptureSampleState();
}

class _ScreenCaptureSampleState extends State<ScreenCaptureSample> {
  StreamSubscription<CShieldEvent>? _sub;
  String? _warning;
  bool _protected = false;

  @override
  void initState() {
    super.initState();
    _sub = CShieldEmbedded.events.listen((event) {
      debugPrint('[SC-DEBUG] event=$event');
      if (event is ScreenCaptureDetected) {
        setState(() => _warning = 'The screen is being recorded or mirrored.');
      }
    });
  }

  Future<void> _enableProtection() async {
    await CShieldScreenCapture.enableProtection();
    setState(() => _protected = true);
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Screen capture')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text(
              'Start a screen recording from Control Center: a warning appears. '
              'After enabling protection, the recording shows a black screen.'),
          const SizedBox(height: 16),
          if (_warning != null)
            Text(_warning!,
                style: const TextStyle(
                    color: Colors.deepOrange, fontWeight: FontWeight.bold)),
          const SizedBox(height: 16),
          FilledButton.tonal(
            onPressed: _protected ? null : _enableProtection,
            child: Text(_protected
                ? 'Protection enabled'
                : 'Enable protection (enableProtection)'),
          ),
          TextButton(
            onPressed: () => setState(() => _warning = null),
            child: const Text('Clear warning'),
          ),
        ],
      ),
    );
  }
}
