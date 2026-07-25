class AccountInfo {
  final String username;
  final String password;
  final String cookies;

  AccountInfo({
    required this.username,
    required this.password,
    this.cookies = '',
  });

  Map<String, dynamic> toJson() => {
        'username': username,
        'password': password,
        'cookies': cookies,
      };

  factory AccountInfo.fromJson(Map<String, dynamic> json) => AccountInfo(
        username: json['username'] ?? '',
        password: json['password'] ?? '',
        cookies: json['cookies'] ?? '',
      );

  bool get isEmpty => username.isEmpty && password.isEmpty;

  AccountInfo copyWith({
    String? username,
    String? password,
    String? cookies,
  }) {
    return AccountInfo(
      username: username ?? this.username,
      password: password ?? this.password,
      cookies: cookies ?? this.cookies,
    );
  }
}
