/// 日志脱敏（收窄版）。
///
/// **只遮蔽两样东西**：
/// 1. **LunaTV 服务器地址** —— 用户配置的主服务器 / 备用服务器地址。
///    这些地址通过 [registerServerAddress] 登记，登记后其 host、host:port
///    与完整 URL 在日志中统一显示为 `***`。
/// 2. **账号密码类凭据** —— `password` / `username` / `token` / `cookie` 等
///    键值对的值，以及 URL 中的 `user:pass@` 形式。
///
/// **刻意不遮蔽**：媒体流地址、第三方接口地址、裸 IP、裸域名、堆栈里的
/// 文件名等一切其它信息 —— 这些是排障时最需要看到的内容。
///
/// 本类**幂等**：重复调用结果不变。
class LogRedactor {
  LogRedactor._();

  /// 已登记的敏感地址片段（按长度降序，先长后短，避免「先遮主机名导致
  /// 完整 URL 片段匹配不到」）。
  static final List<String> _addressTokens = <String>[];

  /// 已登记地址对应的 host（不含端口），供原生层（鸿蒙 ArkTS）同步使用。
  static final List<String> _sensitiveHosts = <String>[];

  /// 凭据类键名（小写匹配）。
  static const List<String> _credKeys = <String>[
    'password',
    'passwd',
    'pwd',
    'pass',
    'username',
    'user_name',
    'token',
    'access_token',
    'refresh_token',
    'cookie',
    'set-cookie',
    'authorization',
    'secret',
    'api_key',
    'apikey',
  ];

  /// 中文凭据键名。
  static const List<String> _cjkCredKeys = <String>[
    '密码',
    '口令',
    '用户名',
    '账号',
    '帐号',
  ];

  /// 遮蔽占位符。
  static const String mask = '***';

  /// 登记一个需要遮蔽的 LunaTV 服务器地址。
  ///
  /// 可传入完整 URL（`https://luna.example.com:8443`）或仅 host。
  /// 重复登记同一地址无副作用。地址变化时旧的登记项仍然保留，
  /// 这样「改了服务器地址」之前产生的日志同样受保护。
  static void registerServerAddress(String? url) {
    final raw = url?.trim();
    if (raw == null || raw.isEmpty) return;

    final tokens = <String>{};
    var host = raw;

    // 去掉协议与路径，取出 host[:port]
    final schemeIdx = raw.indexOf('://');
    if (schemeIdx >= 0) {
      final rest = raw.substring(schemeIdx + 3);
      final slash = rest.indexOf('/');
      host = slash >= 0 ? rest.substring(0, slash) : rest;
    } else {
      final slash = raw.indexOf('/');
      if (slash >= 0) host = raw.substring(0, slash);
    }

    // 去掉 userinfo（user:pass@host）
    final at = host.lastIndexOf('@');
    if (at >= 0) host = host.substring(at + 1);

    if (host.isEmpty) return;

    tokens.add(host); // host[:port] 或 host
    if (host.contains(':')) {
      tokens.add(host.split(':').first); // 仅 host
    }

    // 注：只登记 host / host:port，不登记含 scheme 的完整 URL ——
    // 这样遮蔽后仍保留 `https://` 前缀，日志里能看出用的是哪种协议，
    // 而地址本身（host + 端口）已经不可见。

    for (final t in tokens) {
      if (t.isEmpty) continue;
      if (!_addressTokens.contains(t)) {
        _addressTokens.add(t);
        _addressTokens.sort((a, b) => b.length.compareTo(a.length));
      }
    }

    final bareHost = host.contains(':') ? host.split(':').first : host;
    if (bareHost.isNotEmpty && !_sensitiveHosts.contains(bareHost)) {
      _sensitiveHosts.add(bareHost);
    }
  }

  /// 已登记的敏感 host 列表（供原生层同步）。
  static List<String> get sensitiveHosts => List<String>.unmodifiable(_sensitiveHosts);

  /// 清除全部登记（仅测试或登出场景使用）。
  static void reset() {
    _addressTokens.clear();
    _sensitiveHosts.clear();
  }

  /// 判断这一行是否可能含敏感信息（廉价快速路径）。
  ///
  /// 绝大多数 mpv / ffmpeg 原生日志既不含已登记地址、也不含凭据关键字，
  /// 走这条路径可以完全跳过正则处理。
  static bool _maybeSensitive(String s) {
    final lower = s.toLowerCase();
    if (_addressTokens.isNotEmpty) {
      for (final t in _addressTokens) {
        if (lower.contains(t.toLowerCase())) return true;
      }
    }
    for (final k in _credKeys) {
      if (lower.contains(k)) return true;
    }
    for (final k in _cjkCredKeys) {
      if (s.contains(k)) return true;
    }
    return false;
  }

  /// 遮蔽 URL 中的 `user:pass@`（保留 scheme 与 host）。
  ///
  /// 只在确实存在 userinfo 时才会命中。
  static final RegExp _userInfoRe = RegExp(
    r'([a-zA-Z][a-zA-Z0-9+.\-]*://)([^/\s/?#@\x27"]*@)',
  );

  /// 遮蔽凭据键值对：`password=xxx` / `"password":"xxx"`。
  static final RegExp _kvRe = RegExp(
    r'((?:password|passwd|pwd|pass|username|user_name|token|access_token|refresh_token|cookie|set-cookie|authorization|secret|api_key|apikey)\s*["\x27]?\s*[:=]\s*["\x27]?)([^"\x27\s,;&}\]]+)',
    caseSensitive: false,
  );

  /// 遮蔽中文凭据：`密码 123456`、`密码：123456`。
  static final RegExp _cjkKvRe = RegExp(
    r'((?:密码|口令|用户名|账号|帐号)\s*[:：]?\s*)(\S+)',
  );

  /// 对一行日志做脱敏。**幂等**：重复调用结果不变。
  static String redact(String input) {
    if (input.isEmpty) return input;
    if (!_maybeSensitive(input)) return input;

    var out = input;

    // 1) 已登记的 LunaTV 服务器地址
    for (final token in _addressTokens) {
      if (out.isEmpty) break;
      out = out.replaceAll(token, mask);
    }

    // 2) URL 中的用户名密码（保留 scheme 与 host）
    out = out.replaceAllMapped(_userInfoRe, (m) => '${m.group(1)}$mask@');

    // 3) 凭据键值对
    out = out.replaceAllMapped(_kvRe, (m) => '${m.group(1)}$mask');

    // 4) 中文凭据
    out = out.replaceAllMapped(_cjkKvRe, (m) => '${m.group(1)}$mask');

    return out;
  }
}
