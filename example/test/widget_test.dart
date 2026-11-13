import 'package:c_shield_embedded/c_shield_embedded.dart';
import 'package:c_shield_embedded_example/samples/error_handling.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('messageFor covers every error code with a non-empty message', () {
    for (final code in CShieldErrorCode.values) {
      expect(messageFor(CShieldException(code, 'detail')), isNotEmpty,
          reason: code.name);
    }
  });

  test(
      'a retryable notReady asks the user to try again; a permanent one does not',
      () {
    const retryable = CShieldException(
        CShieldErrorCode.notReady, 'starting', null, true, 'INITIALIZING');
    const permanent = CShieldException(CShieldErrorCode.notReady,
        'device_blocked', null, false, 'UNAVAILABLE');

    expect(messageFor(retryable), contains('try again'));
    expect(messageFor(permanent), contains('device_blocked'));
  });
}
