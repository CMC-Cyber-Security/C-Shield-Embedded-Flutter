import 'dart:convert';

import '../../api/exceptions/c_shield_exception.dart';

/// Pure-Dart port of the native canonical path+query builder
/// (`CShieldInterceptor.canonicalQuery` / `canonicalPathAndQuery` on Android,
/// the equivalent on iOS) and the server's `parseQueryPairs` + `canonicalQuery`.
///
/// After the CS-01 / CS-02 / CS-04 server fix the signed/verified payload embeds
/// the query string in **canonical** form:
///
/// ```
/// request : {METHOD}.{path}[?{canonicalQuery}].{timestamp}.{bodyHash}
/// response: {statusCode}.{path}[?{canonicalQuery}].{timestamp}.{bodyHash}
/// ```
///
/// The canonical form is invariant to parameter order and to how the query was
/// originally percent-encoded on the wire, so the signature survives proxies /
/// CDNs / WAFs that reorder params or decode+re-encode the query. When there is
/// no query the `[?canonicalQuery]` part is dropped entirely.
///
/// The path itself (everything before `?`) is taken **raw** — never decoded,
/// normalized, or stripped of any mount prefix — matching `req.originalUrl` on
/// the server and `encodedPath` on Android.
class AIPCanonicalQuery {
  AIPCanonicalQuery._();

  static const _hexDigits = '0123456789ABCDEF';

  /// Builds `path[?canonicalQuery]` for [uri].
  ///
  /// The returned string is used **verbatim** for both signing the request and
  /// verifying its response — callers must capture it at sign time and reuse the
  /// exact same string when verifying, never recompute it from a later URL (a
  /// followed redirect would change it).
  static String pathAndQuery(Uri uri) {
    final query = canonicalQuery(uri.query);
    return query.isEmpty ? uri.path : '${uri.path}?$query';
  }

  /// Canonicalizes a raw (still percent-encoded) query string — the part after
  /// `?` and before `#`, e.g. Dart's [Uri.query].
  ///
  /// Mirrors native/server exactly:
  ///  1. split on `&`, drop empty segments (`a=1&&b=2`, a lone `?`);
  ///  2. split each pair at the FIRST `=` into (key, value);
  ///  3. percent-decode both with [_percentDecode] (`+` kept literal — NOT a space);
  ///  4. re-encode both with [_rfc3986Encode] (fixed RFC 3986 unreserved set);
  ///  5. sort by encoded key, then by encoded value (plain ASCII string compare);
  ///  6. join `key=value` pairs with `&`.
  ///
  /// Returns `''` when there is no query or the query carries no parameters —
  /// the two cases are intentionally merged, matching the server convention.
  ///
  /// Throws [CShieldException] ([CShieldErrorCode.aipSigningFailed]) — fail-closed
  /// — on malformed percent-encoding or an unpaired UTF-16 surrogate in a
  /// parameter, so a request is never signed with bytes that differ from what
  /// the app intended to send.
  static String canonicalQuery(String? rawQuery) {
    if (rawQuery == null || rawQuery.isEmpty) return '';

    final pairs = <_Pair>[];
    for (final rawPair in rawQuery.split('&')) {
      if (rawPair.isEmpty) continue;
      final eq = rawPair.indexOf('=');
      final rawKey = eq == -1 ? rawPair : rawPair.substring(0, eq);
      final rawValue = eq == -1 ? '' : rawPair.substring(eq + 1);
      pairs.add(_Pair(
        _rfc3986Encode(_percentDecode(rawKey)),
        _rfc3986Encode(_percentDecode(rawValue)),
      ));
    }
    if (pairs.isEmpty) return '';

    pairs.sort((a, b) {
      final byKey = a.key.compareTo(b.key);
      return byKey != 0 ? byKey : a.value.compareTo(b.value);
    });
    return pairs.map((p) => '${p.key}=${p.value}').join('&');
  }

  /// Percent-decodes one query component.
  ///
  /// Manual byte-by-byte decode (mirrors Android's `percentDecode`): `+` is kept
  /// as a literal `+`, never turned into a space, because the server decodes with
  /// a plain `decodeURIComponent`. Input is expected to be pure ASCII — anything
  /// outside the wire query alphabet (non-ASCII, malformed `%XX`) is a corrupted
  /// input and fails closed.
  static String _percentDecode(String raw) {
    final bytes = <int>[];
    var i = 0;
    while (i < raw.length) {
      final ch = raw.codeUnitAt(i);
      if (ch == 0x25) {
        // '%'
        if (i + 2 >= raw.length) {
          throw const CShieldException(
            CShieldErrorCode.aipSigningFailed,
            'Malformed percent-encoding in query — refusing to sign request',
          );
        }
        final hi = _hexValue(raw.codeUnitAt(i + 1));
        final lo = _hexValue(raw.codeUnitAt(i + 2));
        if (hi < 0 || lo < 0) {
          throw const CShieldException(
            CShieldErrorCode.aipSigningFailed,
            'Malformed percent-encoding in query — refusing to sign request',
          );
        }
        bytes.add((hi << 4) | lo);
        i += 3;
      } else if (ch <= 0x7F) {
        bytes.add(ch);
        i++;
      } else {
        throw const CShieldException(
          CShieldErrorCode.aipSigningFailed,
          'Unexpected non-ASCII byte in encoded query — refusing to sign request',
        );
      }
    }
    // Decode as UTF-8 so adjacent multi-byte %XX sequences combine correctly.
    try {
      return utf8.decode(bytes);
    } on FormatException catch (e) {
      throw CShieldException(
        CShieldErrorCode.aipSigningFailed,
        'Malformed UTF-8 in query parameter — refusing to sign request',
        e,
      );
    }
  }

  /// Percent-encodes one query component per RFC 3986: keeps only the unreserved
  /// set `A-Za-z0-9-_.~`, everything else becomes `%XX` with UPPERCASE hex —
  /// including `! ' ( ) *` which `Uri.encodeQueryComponent` would leave alone.
  ///
  /// Fails closed on an unpaired UTF-16 surrogate (a value corrupted by a bad
  /// string split somewhere upstream): `utf8.encode` would silently replace it
  /// with U+FFFD, which must never be signed as if it were the app's data
  /// (matches Android's `CodingErrorAction.REPORT`).
  static String _rfc3986Encode(String value) {
    _checkNoLoneSurrogates(value);

    final buffer = StringBuffer();
    for (final b in utf8.encode(value)) {
      final isUnreserved = (b >= 0x41 && b <= 0x5A) || // A-Z
          (b >= 0x61 && b <= 0x7A) || // a-z
          (b >= 0x30 && b <= 0x39) || // 0-9
          b == 0x2D || // -
          b == 0x5F || // _
          b == 0x2E || // .
          b == 0x7E; // ~
      if (isUnreserved) {
        buffer.writeCharCode(b);
      } else {
        buffer
          ..write('%')
          ..write(_hexDigits[b >> 4])
          ..write(_hexDigits[b & 0x0F]);
      }
    }
    return buffer.toString();
  }

  static void _checkNoLoneSurrogates(String value) {
    for (var i = 0; i < value.length; i++) {
      final unit = value.codeUnitAt(i);
      if (unit >= 0xD800 && unit <= 0xDBFF) {
        final hasLowSurrogate = i + 1 < value.length &&
            value.codeUnitAt(i + 1) >= 0xDC00 &&
            value.codeUnitAt(i + 1) <= 0xDFFF;
        if (!hasLowSurrogate) _throwInvalidChars();
        i++; // valid pair — skip the low surrogate
      } else if (unit >= 0xDC00 && unit <= 0xDFFF) {
        _throwInvalidChars(); // lone low surrogate
      }
    }
  }

  static Never _throwInvalidChars() => throw const CShieldException(
        CShieldErrorCode.aipSigningFailed,
        'Invalid characters in query parameter — refusing to sign request',
      );

  /// Value of a single ASCII hex digit code unit, or -1 if it is not one.
  /// Explicit check (no `int.parse`) so `%+F`, `%-1`, whitespace, etc. all fail.
  static int _hexValue(int codeUnit) {
    if (codeUnit >= 0x30 && codeUnit <= 0x39) return codeUnit - 0x30; // 0-9
    if (codeUnit >= 0x41 && codeUnit <= 0x46) return codeUnit - 0x41 + 10; // A-F
    if (codeUnit >= 0x61 && codeUnit <= 0x66) return codeUnit - 0x61 + 10; // a-f
    return -1;
  }
}

class _Pair {
  final String key;
  final String value;
  const _Pair(this.key, this.value);
}
