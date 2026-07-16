#
# To learn more about a Podspec see http://guides.cocoapods.org/syntax/podspec.html.
# Run `pod lib lint flutter_mpv_video.podspec` to validate before publishing.
#

require_relative '../common/darwin/Podspec/flutter_mpv_utils.rb'

Pod::Spec.new do |s|
  # Setup required files
  system("make -C ../common/darwin HEADERS_DESTDIR=\"$(pwd)/Headers\"")

  # Initialize `FlutterMpvUtils`
  mku = FlutterMpvUtils.new(FlutterMpvUtils::Platform::MACOS)

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
  s.platform         = :osx, '10.9'
  s.swift_version    = '5.0'
  s.dependency         'FlutterMacOS'

  if mku.libs_found
    # Define paths to frameworks dir
    framework_search_paths_macosx = sprintf('$(PROJECT_DIR)/../Flutter/ephemeral/.symlinks/plugins/%s/macos/Frameworks/.symlinks/mpv/macos', mku.libs_package)

    s.source_files        = 'Classes/plugin/**/*.swift', 'Headers/**/*.h'
    s.pod_target_xcconfig = {
      'DEFINES_MODULE'                      => 'YES',
      'GCC_WARN_INHIBIT_ALL_WARNINGS'       => 'YES',
      'GCC_PREPROCESSOR_DEFINITIONS'        => '"$(inherited)" GL_SILENCE_DEPRECATION COREVIDEO_SILENCE_GL_DEPRECATION',
      'FRAMEWORK_SEARCH_PATHS[sdk=macosx*]' => sprintf('"$(inherited)" "%s"', framework_search_paths_macosx),
      'OTHER_LDFLAGS'                       => '"$(inherited)" -framework Mpv',
    }
  else
    s.source_files        = 'Classes/stub/**/*.swift'
    s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }
  end
end
