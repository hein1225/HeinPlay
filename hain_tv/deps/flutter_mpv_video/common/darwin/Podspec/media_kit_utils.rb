class FlutterMpvUtils
  attr_accessor :libs_found, :libs_package

  module Platform
    IOS   ||= 'ios'
    MACOS ||= 'macos'
  end

  module Type
    AUDIO ||= 'audio'
    VIDEO ||= 'video'
  end

  def initialize(platform)
    raise "Expecting '#{Platform::IOS}' or '#{Platform::MACOS}': platform = #{platform}" if
      !(platform == Platform::IOS || platform == Platform::MACOS)

    # Find the nearest path to `pubspec.lock` using `PWD` env var set by
    # `cocoapods`
    current_dir       = ENV['PWD'] || '/'
    pubspec_lock_path = FlutterMpvUtils::find_nearest_pubspec_lock(current_dir)

    # If not found try again using `PWD_FALLBACK` env var manually set,
    # `PWD_FALLBACK` must point to app folder or any child folder
    if pubspec_lock_path == ''
      current_dir       = ENV['PWD_FALLBACK'] || '/'
      pubspec_lock_path = FlutterMpvUtils::find_nearest_pubspec_lock(current_dir)
    end

    # Abort if no `pubspec.lock` was found
    if pubspec_lock_path == ''
      abort(
        sprintf(
          'flutter_mpv: ERROR: No pubspec.lock was found: ENV["PWD"] = "%s"',
          ENV["PWD"]
        )
      )
    end

    # Load packages from `pubspec.lock`
    pubspec_lock          = YAML.load_file(pubspec_lock_path)
    packages              = pubspec_lock['packages']
    
    # Checks for `flutter_mpv_libs_***` in `pubspec.lock`
    libs_count    = 0
    @libs_package = ''
    Type.constants.each do |constant|
      type    = Type.const_get(constant)
      package = sprintf('flutter_mpv_libs_%s_%s', platform, type)
      if packages.keys.include?(package)
        libs_count    += 1
        @libs_package = package

        puts sprintf('flutter_mpv: INFO: package:%s found', package)
      end
    end

    # Abort if multiple `flutter_mpv_libs_***` was found
    if libs_count > 1
      abort(
        sprintf(
          'flutter_mpv: ERROR: package:flutter_mpv_libs_%s_*** must be uniq',
          platform,
        )
      )
    end

    @libs_found = libs_count > 0

    # Warn if no `flutter_mpv_libs_*` was found
    if !@libs_found
      warn(
        sprintf(
          'flutter_mpv: WARNING: package:flutter_mpv_libs_%s_*** not found',
          platform
        )
      )
    end
  end

  # Looks for the nearest `pubspec.lock` by recursively ascending through the
  # parent folders
  def self.find_nearest_pubspec_lock(current_dir)
    while current_dir != '/'
      path = File.join(current_dir, 'pubspec.lock')
      if File.exist?(path)
        return path
      else
        current_dir = File.expand_path('..', current_dir)
      end
    end

    return ''
  end
end
