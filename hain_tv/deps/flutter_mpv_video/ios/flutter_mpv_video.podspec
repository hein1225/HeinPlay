#
# To learn more about a Podspec see http://guides.cocoapods.org/syntax/podspec.html.
# Run `pod lib lint flutter_mpv_video.podspec` to validate before publishing.
#

require_relative '../common/darwin/Podspec/flutter_mpv_utils.rb'

Pod::Spec.new do |s|
  # Setup required files
  system("make -C ../common/darwin HEADERS_DESTDIR=\"$(pwd)/Headers\"")

  # Initialize `FlutterMpvUtils`
  mku = FlutterMpvUtils.new(FlutterMpvUtils::Platform::IOS)

  s.name             = 'flutter_mpv_video'
  s.version          = '0.0.1'
  s.summary          = 'Native implementation for video playback in package:flutter_mpv'
  s.description      = <<-DESC
  Native implementation for video playback in package:flutter_mpv.
                       DESC
  s.homepage         = 'https://github.com/media-kit/media-kit.git'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'Hitesh Kumar Saini' => 'saini123hitesh@gmail.com' }

  s.source           = { :path => '.' }
  s.platform         = :ios, '9.0'
  s.swift_version    = '5.0'
  s.dependency         'Flutter'
  
  if mku.libs_found
    # Define paths to frameworks dir
    framework_search_paths_iphoneos        = sprintf('$(PROJECT_DIR)/../.symlinks/plugins/%s/ios/Frameworks/.symlinks/mpv/ios', mku.libs_package)
    framework_search_paths_iphonesimulator = sprintf('$(PROJECT_DIR)/../.symlinks/plugins/%s/ios/Frameworks/.symlinks/mpv/ios-simulator', mku.libs_package)

    s.source_files        = 'Classes/plugin/**/*.swift', 'Headers/**/*.h'
    s.pod_target_xcconfig = {
      'DEFINES_MODULE'                               => 'YES',
      'GCC_WARN_INHIBIT_ALL_WARNINGS'                => 'YES',
      'GCC_PREPROCESSOR_DEFINITIONS'                 => '"$(inherited)" GL_SILENCE_DEPRECATION COREVIDEO_SILENCE_GL_DEPRECATION',
      'FRAMEWORK_SEARCH_PATHS[sdk=iphoneos*]'        => sprintf('"$(inherited)" "%s"', framework_search_paths_iphoneos),
      'FRAMEWORK_SEARCH_PATHS[sdk=iphonesimulator*]' => sprintf('"$(inherited)" "%s"', framework_search_paths_iphonesimulator),
      'OTHER_LDFLAGS'                                => '"$(inherited)" -framework Mpv',
      # Flutter.framework does not contain a i386 slice.
      'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386',
    }
  else
    s.source_files        = 'Classes/stub/**/*.swift'
    s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }
  end
end
