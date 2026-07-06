class LiveChannel {
  final String name;
  final String url;
  final String? logo;
  final String? tvgId;
  final String? group;

  LiveChannel({
    required this.name,
    required this.url,
    this.logo,
    this.tvgId,
    this.group,
  });

  factory LiveChannel.fromJson(Map<String, dynamic> json) {
    return LiveChannel(
      name: json['name']?.toString() ?? '',
      url: json['url']?.toString() ?? '',
      logo: json['logo']?.toString(),
      tvgId: json['tvgId']?.toString() ?? json['tvg_id']?.toString(),
      group: json['group']?.toString() ?? json['group_title']?.toString(),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'name': name,
      'url': url,
      'logo': logo,
      'tvgId': tvgId,
      'group': group,
    };
  }
}
