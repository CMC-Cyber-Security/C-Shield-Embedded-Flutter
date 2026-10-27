import 'package:c_shield_embedded/src/api/attest/c_shield_state.dart';
import 'package:c_shield_embedded/src/api/attest/ensure_trust_result.dart';
import 'package:c_shield_embedded/src/api/attest/trust_level.dart';
import 'package:c_shield_embedded/src/api/event/c_shield_event.dart';
import 'package:flutter_test/flutter_test.dart';

/// Mirrors `TrustLevelTest.kt` (android) — map tên enum cross method-channel + so ngưỡng
/// (logic điều hướng của `ensureTrust`). Enum phải khớp TÊN native, nếu không trust bị đọc sai.
void main() {
  group('TrustLevel', () {
    test('fromId maps native names, case-insensitively', () {
      expect(TrustLevel.fromId('L0'), TrustLevel.l0);
      expect(TrustLevel.fromId('l4'), TrustLevel.l4);
      expect(TrustLevel.fromId(' L5 '), TrustLevel.l5);
      expect(TrustLevel.fromId('UNKNOWN'), TrustLevel.unknown);
    });

    test('fromId falls back to unknown for null/empty/garbage', () {
      expect(TrustLevel.fromId(null), TrustLevel.unknown);
      expect(TrustLevel.fromId(''), TrustLevel.unknown);
      expect(TrustLevel.fromId('L9'), TrustLevel.unknown);
    });

    test('atLeast compares on the L0–L5 scale', () {
      expect(TrustLevel.l4.atLeast(TrustLevel.l4), isTrue);
      expect(TrustLevel.l5.atLeast(TrustLevel.l4), isTrue);
      expect(TrustLevel.l3.atLeast(TrustLevel.l4), isFalse);
    });

    test('unknown (chưa đăng ký) luôn thấp hơn mọi mức hợp lệ → ensureTrust buộc nâng', () {
      expect(TrustLevel.unknown.atLeast(TrustLevel.l0), isFalse);
      expect(TrustLevel.unknown.atLeast(TrustLevel.l5), isFalse);
    });
  });

  group('CShieldState / EnsureTrustResult', () {
    test('fromId maps native names', () {
      expect(CShieldState.fromId('INITIALIZING'), CShieldState.initializing);
      expect(CShieldState.fromId('READY'), CShieldState.ready);
      expect(CShieldState.fromId('DEGRADED'), CShieldState.degraded);
      expect(EnsureTrustResult.fromId('SATISFIED'), EnsureTrustResult.satisfied);
      expect(EnsureTrustResult.fromId('RATE_LIMITED'), EnsureTrustResult.rateLimited);
    });

    test('tên lạ/null → mức không khả dụng (fail-closed, vd iOS chưa hỗ trợ attest v2)', () {
      expect(CShieldState.fromId(null), CShieldState.unavailable);
      expect(CShieldState.fromId('WAT'), CShieldState.unavailable);
      expect(EnsureTrustResult.fromId(null), EnsureTrustResult.unavailable);
    });
  });

  group('AttestStateChanged event', () {
    test('parses the native event payload', () {
      final event = CShieldEvent.fromMap({
        'event': 'onAttestStateChanged',
        'state': 'DEGRADED',
        'trustLevel': 'L1',
        'lastError': 'network',
      });

      expect(event, isA<AttestStateChanged>());
      final e = event as AttestStateChanged;
      expect(e.state, CShieldState.degraded);
      expect(e.trustLevel, TrustLevel.l1);
      expect(e.lastError, 'network');
    });

    test('lastError null khi chưa có lỗi', () {
      final e = CShieldEvent.fromMap({
            'event': 'onAttestStateChanged',
            'state': 'READY',
            'trustLevel': 'L3',
            'lastError': null,
          }) as AttestStateChanged;

      expect(e.state, CShieldState.ready);
      expect(e.trustLevel, TrustLevel.l3);
      expect(e.lastError, isNull);
    });
  });
}
