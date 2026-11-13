#
# To learn more about a Podspec see http://guides.cocoapods.org/syntax/podspec.html.
# Run `pod lib lint c_shield_embedded.podspec` to validate before publishing.
#
Pod::Spec.new do |s|
  s.name             = 'c_shield_embedded'
  s.version          = '1.0.4'
  s.summary          = 'CShield Embedded Flutter SDK plugin for iOS'
  s.description      = 'Flutter plugin wrapping the CShieldEmbedded XCFramework (AIP request signing, device attestation, SSL pinning, anti-keylogger).'
  s.homepage         = 'https://github.com/CMC-Cyber-Security/C-Shield-Embedded-Flutter'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'CMCCS' => 'email@example.com' }
  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*'
  s.dependency 'Flutter'
  s.platform = :ios, '13.0'

  # CShieldEmbedded is not bundled in the plugin: the host app provides it under
  # Libs/Debug|Release/. Declaring the framework makes CocoaPods add
  # `-framework CShieldEmbedded` to OTHER_LDFLAGS. The variant-specific
  # FRAMEWORK_SEARCH_PATHS must be set in the host app's Podfile
  # (see doc/ios-host-app-integration.md).
  s.frameworks = 'CShieldEmbedded'

  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386'
  }
  s.swift_version = '5.0'
end
