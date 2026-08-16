import 'dart:math';

/// 本地直播源配置模型。
class LiveSourceConfig {
  final String id;
  final String name;
  final String url;
  final String? epgUrl;
  final String? sourceKey;
  final bool isLocal;
  final bool isBuiltin;
  final bool enabled;
  final int order;
  final DateTime createTime;

  LiveSourceConfig({
    required this.id,
    required this.name,
    required this.url,
    this.epgUrl,
    this.sourceKey,
    this.isLocal = false,
    this.isBuiltin = false,
    this.enabled = true,
    this.order = 0,
    required this.createTime,
  });

  factory LiveSourceConfig.fromJson(Map<String, dynamic> json) {
    return LiveSourceConfig(
      id: json['id']?.toString() ?? '',
      name: json['name']?.toString() ?? '',
      url: json['url']?.toString() ?? '',
      epgUrl: json['epgUrl']?.toString(),
      sourceKey: json['sourceKey']?.toString(),
      isLocal: json['isLocal'] == true,
      isBuiltin: json['isBuiltin'] == true,
      enabled: json['enabled'] != false,
      order: json['order'] ?? 0,
      createTime: DateTime.tryParse(json['createTime'] ?? '') ?? DateTime.now(),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'url': url,
      'epgUrl': epgUrl,
      'sourceKey': sourceKey,
      'isLocal': isLocal,
      'isBuiltin': isBuiltin,
      'enabled': enabled,
      'order': order,
      'createTime': createTime.toIso8601String(),
    };
  }

  LiveSourceConfig copyWith({
    String? id,
    String? name,
    String? url,
    String? epgUrl,
    String? sourceKey,
    bool? isLocal,
    bool? isBuiltin,
    bool? enabled,
    int? order,
    DateTime? createTime,
  }) {
    return LiveSourceConfig(
      id: id ?? this.id,
      name: name ?? this.name,
      url: url ?? this.url,
      epgUrl: epgUrl ?? this.epgUrl,
      sourceKey: sourceKey ?? this.sourceKey,
      isLocal: isLocal ?? this.isLocal,
      isBuiltin: isBuiltin ?? this.isBuiltin,
      enabled: enabled ?? this.enabled,
      order: order ?? this.order,
      createTime: createTime ?? this.createTime,
    );
  }

  static String generateId() {
    final random = Random.secure();
    final values = List<int>.generate(16, (_) => random.nextInt(256));
    return values.map((v) => v.toRadixString(16).padLeft(2, '0')).join('');
  }
}
