class CShieldChannels {
  static const String methodChannel = 'c_shield_embedded';

  static const String sdkInitialize = 'sdk.initialize';

  static const String sslConfigure = 'ssl.configure';
  static const String sslUpdatePins = 'ssl.updatePins';
  static const String sslIsConfigured = 'ssl.isConfigured';
  static const String sslCheckServerTrusted = 'ssl.checkServerTrusted';

  // Performs an HTTPS request entirely on the native side (OkHttp on Android,
  // URLSession on iOS) so that certificate pinning runs at the native TLS layer
  // with the FULL certificate chain — enabling intermediate/root pin matching
  // that pure-Dart networking cannot do (dart:io only exposes the leaf cert).
  static const String sslHttpRequest = 'ssl.httpRequest';

  // AIP — only the cryptographic sign/verify cross to native. Body
  // normalization, payload construction and the timestamp-window check are
  // done in Dart (CShieldAIP / AIPNormalizer).
  static const String aipSign = 'aip.sign';
  static const String aipVerify = 'aip.verify';
   static const String aipSignRequest = 'aip.signRequest';
}
