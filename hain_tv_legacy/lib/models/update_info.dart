class UpdateInfo {
  final String version;
  final String tagName;
  final String title;
  final String body;
  final String htmlUrl;
  final String? apkUrl;

  UpdateInfo({
    required this.version,
    required this.tagName,
    required this.title,
    required this.body,
    required this.htmlUrl,
    this.apkUrl,
  });
}
