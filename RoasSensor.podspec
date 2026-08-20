Pod::Spec.new do |s|
  s.name             = 'RoasSensor'
  s.version          = '0.1.7'
  s.summary          = 'ROASSensor iOS tracking SDK — install attribution, funnel events, identity.'
  s.description      = <<-DESC
    Native iOS tracking for ROASSensor: install reporting (Apple Search Ads
    token, IDFA/ATT, IDFV, SKAdNetwork registration), deferred deep-link
    attribution, on-device email/phone hashing, and funnel events. Revenue is
    never sent from the app — it enters only through the signed RevenueCat
    webhook. Speaks the same /api/tracking/mobile/* wire format as the
    Android SDK. See README.md for the full API.
  DESC
  s.homepage         = 'https://github.com/rishabhrk2345/Roas-ios-SDK'
  s.license          = { :type => 'Proprietary', :text => 'Copyright Vasundhara Infotech LLP. All rights reserved.' }
  s.author           = { 'ROASSensor' => 'support@roassensor.com' }

  # Resolvable as of 0.1.6. CocoaPods checks out the TAG named here, so a
  # version bump means tagging the SDK repo as well as editing this line —
  # a bumped version with no matching tag fails to resolve at `pod install`
  # rather than quietly serving the old code.
  #
  # Not on the CocoaPods trunk (no `pod trunk push`), so consumers must name
  # the source themselves:
  #   pod 'RoasSensor', :git => 'https://github.com/rishabhrk2345/Roas-ios-SDK.git', :tag => '0.1.6'
  # or, developing against a checkout:
  #   pod 'RoasSensor', :path => '../../../sdk-ios'
  s.source           = { :git => 'https://github.com/rishabhrk2345/Roas-ios-SDK.git', :tag => s.version.to_s }

  s.source_files     = 'Sources/RoasSensor/**/*.swift'
  s.ios.deployment_target = '14.0'
  s.swift_version    = '5.9'
end
