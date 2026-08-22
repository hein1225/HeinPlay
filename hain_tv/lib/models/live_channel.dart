class LiveChannel {
  final String name;
  final String url;
  /// 同一频道的备选播放地址（M3U 中连续同名同分组 URL）。
  final List<String> backupUrls;
  final String? logo;
  final String? tvgId;
  final String? group;
  /// 国家/地区代码（如 tvg-country），用于决定节目单按哪个时区显示。
  final String? country;
  /// 当前节目单信息（EPG 当前节目标题或源内嵌的节目描述）。
  /// 运行时会被 EPG 拉取结果覆盖，因此非 final。
  String? program;

  /// 回放类型，如 default、append、shift 等。
  final String? catchup;
  /// 回放 URL 模板，支持 ${start}/${stop}/${offset}/${timestamp} 等变量。
  final String? catchupSource;
  /// 回放保留天数。
  final int? catchupDays;

  /// 当前 EPG 节目对象（运行时，不参与序列化）。
  EpgProgram? currentProgram;

  /// 该频道完整 EPG 节目单（运行时，不参与序列化）。
  List<EpgProgram> programs;

  /// 当前正在使用的备选源索引（运行时，不参与序列化）。
  int currentBackupIndex;

  /// 常见国家/地区对应的时区偏移（分钟）。
  static const Map<String, int> _countryOffsets = {
    'cn': 480,
    'tw': 480,
    'hk': 480,
    'mo': 480,
    'jp': 540,
    'kr': 540,
    'sg': 480,
    'us': -300,
    'gb': 60,
    'fr': 120,
    'de': 120,
    'ru': 180,
    'au': 600,
  };

  LiveChannel({
    required this.name,
    required this.url,
    this.backupUrls = const [],
    this.logo,
    this.tvgId,
    this.group,
    this.country,
    this.program,
    this.catchup,
    this.catchupSource,
    this.catchupDays,
    this.currentProgram,
    this.programs = const [],
    this.currentBackupIndex = 0,
  });

  /// 该频道节目单应使用的时区偏移（分钟）。
  /// 若未识别国家/地区，则默认按北京时间（+480），避免受设备时区影响。
  int get timezoneOffsetMinutes {
    if (country != null && country!.isNotEmpty) {
      final offset = _countryOffsets[country!.trim().toLowerCase()];
      if (offset != null) return offset;
    }
    return 480;
  }

  /// 将 UTC 时刻转换为频道所在时区的“墙上时间”。
  DateTime toChannelTimezone(DateTime utc) {
    final offset = Duration(minutes: timezoneOffsetMinutes);
    final shifted = utc.toUtc().add(offset);
    return DateTime(shifted.year, shifted.month, shifted.day, shifted.hour,
        shifted.minute, shifted.second);
  }

  /// 频道所在时区的当前“墙上时间”。
  DateTime get channelNow {
    return toChannelTimezone(DateTime.now().toUtc());
  }

  /// 判断节目是否正在频道所在时区播放。
  bool isProgramCurrent(EpgProgram program) {
    final now = channelNow;
    final start = toChannelTimezone(program.start);
    final stop = toChannelTimezone(program.stop);
    return start.isBefore(now) && stop.isAfter(now);
  }

  /// 判断节目在频道所在时区是否已结束。
  bool isProgramPast(EpgProgram program) {
    return toChannelTimezone(program.stop).isBefore(channelNow);
  }

  /// 节目时长（分钟，按频道时区计算）。
  int programDurationMinutes(EpgProgram program) {
    final start = toChannelTimezone(program.start);
    final stop = toChannelTimezone(program.stop);
    return stop.difference(start).inMinutes;
  }

  /// 节目已播放时长（分钟，按频道时区计算）。
  int programElapsedMinutes(EpgProgram program) {
    final start = toChannelTimezone(program.start);
    final elapsed = channelNow.difference(start).inMinutes;
    final duration = programDurationMinutes(program);
    return elapsed.clamp(0, duration);
  }

  /// 节目进度比例 0.0 ~ 1.0（按频道时区计算）。
  double programProgressRatio(EpgProgram program) {
    final duration = programDurationMinutes(program);
    if (duration <= 0) return 0;
    return programElapsedMinutes(program) / duration;
  }

  /// 从节目单中找出频道所在时区当前正在播放的节目。
  EpgProgram? findCurrentProgram() {
    final now = channelNow;
    for (final program in programs) {
      final start = toChannelTimezone(program.start);
      final stop = toChannelTimezone(program.stop);
      if (start.isBefore(now) && stop.isAfter(now)) {
        return program;
      }
    }
    return null;
  }

  factory LiveChannel.fromJson(Map<String, dynamic> json) {
    return LiveChannel(
      name: json['name']?.toString() ?? '',
      url: json['url']?.toString() ?? '',
      backupUrls: (json['backupUrls'] as List<dynamic>?)
              ?.map((e) => e.toString())
              .toList() ??
          [],
      logo: json['logo']?.toString(),
      tvgId: json['tvgId']?.toString() ?? json['tvg_id']?.toString(),
      group: json['group']?.toString() ?? json['group_title']?.toString(),
      country: json['country']?.toString() ?? json['tvg_country']?.toString(),
      program: json['program']?.toString() ?? json['epg']?.toString(),
      catchup: json['catchup']?.toString(),
      catchupSource: json['catchupSource']?.toString() ?? json['catchup_source']?.toString(),
      catchupDays: json['catchupDays'] is int
          ? json['catchupDays'] as int
          : int.tryParse(json['catchupDays']?.toString() ?? ''),
      programs: (json['programs'] as List<dynamic>?)
              ?.map((e) => EpgProgram.fromJson(e as Map<String, dynamic>))
              .toList() ??
          [],
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'name': name,
      'url': url,
      'backupUrls': backupUrls,
      'logo': logo,
      'tvgId': tvgId,
      'group': group,
      'country': country,
      'program': program,
      'catchup': catchup,
      'catchupSource': catchupSource,
      'catchupDays': catchupDays,
      // 缓存完整节目单，退出重进后可立即恢复显示，无需再次拉取 EPG。
      'programs': programs.map((p) => p.toJson()).toList(),
    };
  }

  LiveChannel copyWith({
    String? name,
    String? url,
    List<String>? backupUrls,
    String? logo,
    String? tvgId,
    String? group,
    String? country,
    String? program,
    String? catchup,
    String? catchupSource,
    int? catchupDays,
    EpgProgram? currentProgram,
    List<EpgProgram>? programs,
    int? currentBackupIndex,
  }) {
    return LiveChannel(
      name: name ?? this.name,
      url: url ?? this.url,
      backupUrls: backupUrls ?? this.backupUrls,
      logo: logo ?? this.logo,
      tvgId: tvgId ?? this.tvgId,
      group: group ?? this.group,
      country: country ?? this.country,
      program: program ?? this.program,
      catchup: catchup ?? this.catchup,
      catchupSource: catchupSource ?? this.catchupSource,
      catchupDays: catchupDays ?? this.catchupDays,
      currentProgram: currentProgram ?? this.currentProgram,
      programs: programs ?? this.programs,
      currentBackupIndex: currentBackupIndex ?? this.currentBackupIndex,
    );
  }

  /// 当前实际播放地址（主 URL 或当前选中的备选 URL）。
  String get currentUrl {
    if (backupUrls.isEmpty || currentBackupIndex <= 0) return url;
    if (currentBackupIndex < backupUrls.length) return backupUrls[currentBackupIndex];
    return url;
  }

  /// 所有可用播放地址（主 URL + 备选 URL）。
  List<String> get allUrls => [url, ...backupUrls];

  /// 是否存在多个播放地址。
  bool get hasMultipleUrls => backupUrls.isNotEmpty;
}

/// EPG 节目单条目。
class EpgProgram {
  final DateTime start;
  final DateTime stop;
  final String title;

  EpgProgram({
    required this.start,
    required this.stop,
    required this.title,
  });

  factory EpgProgram.fromJson(Map<String, dynamic> json) {
    DateTime? parse(String? value) {
      if (value == null || value.isEmpty) return null;
      final dt = DateTime.tryParse(value);
      if (dt == null) return null;
      // 缓存中若带时区标识则保持 UTC，否则将存储的墙上时间视为 UTC，
      // 以便后续统一按频道所在时区转换显示。
      return dt.isUtc ? dt : DateTime.utc(dt.year, dt.month, dt.day, dt.hour,
          dt.minute, dt.second);
    }

    final start = parse(json['start']?.toString()) ?? DateTime.now().toUtc();
    final stop = parse(json['stop']?.toString()) ?? DateTime.now().toUtc();
    return EpgProgram(
      start: start,
      stop: stop,
      title: json['title']?.toString() ?? '',
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'start': start.toIso8601String(),
      'stop': stop.toIso8601String(),
      'title': title,
    };
  }

  bool get isCurrent => start.isBefore(DateTime.now()) && stop.isAfter(DateTime.now());

  bool get isPast => stop.isBefore(DateTime.now());

  /// 节目总时长（分钟）。
  int get durationMinutes => stop.difference(start).inMinutes;

  /// 当前已播放时长（分钟）。
  int get elapsedMinutes => DateTime.now().difference(start).inMinutes.clamp(0, durationMinutes);

  /// 剩余时长（分钟）。
  int get remainingMinutes => durationMinutes - elapsedMinutes;

  /// 进度比例 0.0 ~ 1.0。
  double get progressRatio {
    if (durationMinutes <= 0) return 0;
    return elapsedMinutes / durationMinutes;
  }
}
