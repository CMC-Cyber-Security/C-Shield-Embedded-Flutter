import 'package:c_shield_embedded/c_shield_embedded.dart';
import 'package:c_shield_embedded/src/internal/platform/c_shield_embedded_method_channel.dart';
import 'package:c_shield_embedded/src/internal/platform/c_shield_embedded_platform_interface.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('c_shield_embedded');
  final calls = <MethodCall>[];

  setUp(() {
    CShieldEmbeddedPlatform.instance = MethodChannelCShieldEmbedded();
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return null;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
  });

  test('enableProtection sends screenCapture.enableProtection without arguments', () async {
    await CShieldScreenCapture.enableProtection();

    expect(calls.single.method, 'screenCapture.enableProtection');
    expect(calls.single.arguments, isNull);
  });

  test('enableProtection maps a native error to CShieldException', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      throw PlatformException(code: 'internal', message: 'boom');
    });

    expect(CShieldScreenCapture.enableProtection(), throwsA(isA<CShieldException>()));
  });

  test('decodes onScreenCaptureDetected into ScreenCaptureDetected', () {
    final event = CShieldEvent.fromMap({'event': 'onScreenCaptureDetected'});

    expect(event, isA<ScreenCaptureDetected>());
  });
}
