import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

class RemoteInputService {
  static final RemoteInputService _instance = RemoteInputService._internal();
  factory RemoteInputService() => _instance;
  RemoteInputService._internal();

  HttpServer? _server;
  String? _serverUrl;
  bool get isRunning => _server != null;
  String? get serverUrl => _serverUrl;

  void _setCorsHeaders(HttpResponse response) {
    response.headers.add('Access-Control-Allow-Origin', '*');
    response.headers.add('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
    response.headers.add('Access-Control-Allow-Headers', 'Content-Type');
  }

  final _messageController = StreamController<String>.broadcast();
  Stream<String> get onMessage => _messageController.stream;

  final _loginController = StreamController<Map<String, String>>.broadcast();
  Stream<Map<String, String>> get onLogin => _loginController.stream;

  final _serverConfigController =
      StreamController<Map<String, String>>.broadcast();
  Stream<Map<String, String>> get onServerConfig =>
      _serverConfigController.stream;

  final _subAccountController = StreamController<Map<String, String>>.broadcast();
  Stream<Map<String, String>> get onSubAccount => _subAccountController.stream;

  String _getRemotePageHTML(
    String serverUrl, {
    bool loginMode = false,
    bool serverConfigMode = false,
    bool subAccountMode = false,
    String currentServerUrl = '',
    String currentBackupServerUrl = '',
  }) {
    if (loginMode) {
      return '''
<!DOCTYPE html>
<html>
<head>
  <title>海因影视 - 扫码登录</title>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0, user-scalable=no">
  <style>
    body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, "Helvetica Neue", Arial, sans-serif; display: flex; flex-direction: column; align-items: center; justify-content: center; min-height: 100vh; margin: 0; background-color: #121212; color: white; padding: 20px 0; box-sizing: border-box; }
    h3 { color: #eee; margin-bottom: 8px; }
    p { color: #888; font-size: 14px; margin-bottom: 20px; }
    #container { display: flex; flex-direction: column; align-items: center; width: 90%; max-width: 400px; }
    .field { width: 100%; margin-bottom: 16px; }
    label { display: block; color: #aaa; font-size: 13px; margin-bottom: 6px; }
    input { width: 100%; padding: 15px; font-size: 16px; border-radius: 8px; border: 1px solid #333; background-color: #2a2a2a; color: white; box-sizing: border-box; }
    input::placeholder { color: #666; }
    button { width: 100%; padding: 15px; font-size: 18px; font-weight: bold; border: none; border-radius: 8px; background-color: #E50914; color: white; cursor: pointer; }
    button:active { background-color: #b20710; }
    #status { margin-top: 16px; font-size: 14px; color: #888; }
  </style>
</head>
<body>
  <div id="container">
    <h3>电视端登录</h3>
    <p>输入服务器地址、用户名和密码，电视将自动登录</p>
    <div class="field">
      <label>互联网服务器地址</label>
      <input id="server" placeholder="https://your-lunatv-server.com" />
    </div>
    <div class="field">
      <label>局域网服务器地址（选填）</label>
      <input id="backupServer" placeholder="http://192.168.1.100:3000" />
    </div>
    <div class="field">
      <label>用户名（选填）</label>
      <input id="username" placeholder="数据库模式需填写" />
    </div>
    <div class="field">
      <label>密码</label>
      <input id="password" type="password" placeholder="LunaTV 登录密码" />
    </div>
    <button onclick="sendLogin()">登录</button>
    <div id="status"></div>
  </div>
  <script>
    function setStatus(msg, color) {
      const el = document.getElementById("status");
      el.textContent = msg;
      el.style.color = color || "#888";
    }
    function sendLogin() {
      const server = document.getElementById("server").value.trim();
      const backupServer = document.getElementById("backupServer").value.trim();
      const username = document.getElementById("username").value.trim();
      const password = document.getElementById("password").value.trim();
      if (!server && !backupServer) {
        setStatus("请至少填写一个服务器地址", "#FF6B6B");
        return;
      }
      if (!password) {
        setStatus("请输入密码", "#FF6B6B");
        return;
      }
      setStatus("登录中...", "#888");
      fetch("/login", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ serverUrl: server, backupServerUrl: backupServer, username: username, password: password })
      })
      .then(r => r.json())
      .then(data => {
        if (data.status === "ok") {
          setStatus("已发送，电视正在登录...", "#4CAF50");
        } else {
          setStatus("发送失败: " + (data.error || ""), "#FF6B6B");
        }
      })
      .catch(err => {
        setStatus("发送失败，请检查网络", "#FF6B6B");
      });
    }
    document.getElementById("password").addEventListener("keypress", function(e) {
      if (e.key === "Enter") sendLogin();
    });
  </script>
</body>
</html>
''';
    }
    if (serverConfigMode) {
      return '''
<!DOCTYPE html>
<html>
<head>
  <title>海因影视 - 修改服务器地址</title>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0, user-scalable=no">
  <style>
    body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, "Helvetica Neue", Arial, sans-serif; display: flex; flex-direction: column; align-items: center; justify-content: center; min-height: 100vh; margin: 0; background-color: #121212; color: white; padding: 20px 0; box-sizing: border-box; }
    h3 { color: #eee; margin-bottom: 8px; }
    p { color: #888; font-size: 14px; margin-bottom: 20px; }
    #container { display: flex; flex-direction: column; align-items: center; width: 90%; max-width: 400px; }
    .field { width: 100%; margin-bottom: 16px; }
    label { display: block; color: #aaa; font-size: 13px; margin-bottom: 6px; }
    input { width: 100%; padding: 15px; font-size: 16px; border-radius: 8px; border: 1px solid #333; background-color: #2a2a2a; color: white; box-sizing: border-box; }
    input::placeholder { color: #666; }
    button { width: 100%; padding: 15px; font-size: 18px; font-weight: bold; border: none; border-radius: 8px; background-color: #E50914; color: white; cursor: pointer; }
    button:active { background-color: #b20710; }
    #status { margin-top: 16px; font-size: 14px; color: #888; }
  </style>
</head>
<body>
  <div id="container">
    <h3>修改服务器地址</h3>
    <p>输入互联网/局域网服务器地址后，电视将自动保存</p>
    <div class="field">
      <label>互联网服务器地址</label>
      <input id="server" placeholder="https://your-lunatv-server.com" value="${currentServerUrl.replaceAll('&', '&amp;').replaceAll('"', '&quot;').replaceAll('<', '&lt;').replaceAll('>', '&gt;')}" />
    </div>
    <div class="field">
      <label>局域网服务器地址（选填）</label>
      <input id="backupServer" placeholder="http://192.168.1.100:3000" value="${currentBackupServerUrl.replaceAll('&', '&amp;').replaceAll('"', '&quot;').replaceAll('<', '&lt;').replaceAll('>', '&gt;')}" />
    </div>
    <button onclick="sendConfig()">保存</button>
    <div id="status"></div>
  </div>
  <script>
    function setStatus(msg, color) {
      const el = document.getElementById("status");
      el.textContent = msg;
      el.style.color = color || "#888";
    }
    function sendConfig() {
      const server = document.getElementById("server").value.trim();
      const backupServer = document.getElementById("backupServer").value.trim();
      if (!server && !backupServer) {
        setStatus("请至少填写一个服务器地址", "#FF6B6B");
        return;
      }
      setStatus("保存中...", "#888");
      fetch("/server_config", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ serverUrl: server, backupServerUrl: backupServer })
      })
      .then(r => r.json())
      .then(data => {
        if (data.status === "ok") {
          setStatus("已保存", "#4CAF50");
        } else {
          setStatus("保存失败: " + (data.error || ""), "#FF6B6B");
        }
      })
      .catch(err => {
        setStatus("保存失败，请检查网络", "#FF6B6B");
      });
    }
  </script>
</body>
</html>
''';
    }
    if (subAccountMode) {
      return '''
<!DOCTYPE html>
<html>
<head>
  <title>海因影视 - 输入子账号</title>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0, user-scalable=no">
  <style>
    body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, "Helvetica Neue", Arial, sans-serif; display: flex; flex-direction: column; align-items: center; justify-content: center; min-height: 100vh; margin: 0; background-color: #121212; color: white; padding: 20px 0; box-sizing: border-box; }
    h3 { color: #eee; margin-bottom: 8px; }
    p { color: #888; font-size: 14px; margin-bottom: 20px; }
    #container { display: flex; flex-direction: column; align-items: center; width: 90%; max-width: 400px; }
    .field { width: 100%; margin-bottom: 16px; }
    label { display: block; color: #aaa; font-size: 13px; margin-bottom: 6px; }
    input { width: 100%; padding: 15px; font-size: 16px; border-radius: 8px; border: 1px solid #333; background-color: #2a2a2a; color: white; box-sizing: border-box; }
    input::placeholder { color: #666; }
    button { width: 100%; padding: 15px; font-size: 18px; font-weight: bold; border: none; border-radius: 8px; background-color: #E50914; color: white; cursor: pointer; }
    button:active { background-color: #b20710; }
    #status { margin-top: 16px; font-size: 14px; color: #888; }
  </style>
</head>
<body>
  <div id="container">
    <h3>输入子账号</h3>
    <p>输入用户名和密码，电视将保存并切换到子账号</p>
    <div class="field">
      <label>用户名</label>
      <input id="username" placeholder="数据库模式需填写" />
    </div>
    <div class="field">
      <label>密码</label>
      <input id="password" type="password" placeholder="LunaTV 登录密码" />
    </div>
    <button onclick="sendSubAccount()">保存</button>
    <div id="status"></div>
  </div>
  <script>
    function setStatus(msg, color) {
      const el = document.getElementById("status");
      el.textContent = msg;
      el.style.color = color || "#888";
    }
    function sendSubAccount() {
      const username = document.getElementById("username").value.trim();
      const password = document.getElementById("password").value.trim();
      if (!username || !password) {
        setStatus("请输入用户名和密码", "#FF6B6B");
        return;
      }
      setStatus("保存中...", "#888");
      fetch("/sub_account", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ username: username, password: password })
      })
      .then(r => r.json())
      .then(data => {
        if (data.status === "ok") {
          setStatus("已保存", "#4CAF50");
        } else {
          setStatus("保存失败: " + (data.error || ""), "#FF6B6B");
        }
      })
      .catch(err => {
        setStatus("保存失败，请检查网络", "#FF6B6B");
      });
    }
    document.getElementById("password").addEventListener("keypress", function(e) {
      if (e.key === "Enter") sendSubAccount();
    });
  </script>
</body>
</html>
''';
    }
    return '''
<!DOCTYPE html>
<html>
<head>
  <title>海因影视 - 手机输入</title>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0, user-scalable=no">
  <style>
    body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, "Helvetica Neue", Arial, sans-serif; display: flex; flex-direction: column; align-items: center; justify-content: center; height: 100vh; margin: 0; background-color: #121212; color: white; }
    h3 { color: #eee; margin-bottom: 8px; }
    p { color: #888; font-size: 14px; margin-bottom: 20px; }
    #container { display: flex; flex-direction: column; align-items: center; width: 90%; max-width: 400px; }
    #text { width: 100%; padding: 15px; font-size: 16px; border-radius: 8px; border: 1px solid #333; background-color: #2a2a2a; color: white; margin-bottom: 20px; box-sizing: border-box; }
    button { width: 100%; padding: 15px; font-size: 18px; font-weight: bold; border: none; border-radius: 8px; background-color: #E50914; color: white; cursor: pointer; }
    button:active { background-color: #b20710; }
    #status { margin-top: 16px; font-size: 14px; color: #888; }
  </style>
</head>
<body>
  <div id="container">
    <h3>向电视发送搜索关键词</h3>
    <p>输入完成后点击发送，电视将自动搜索</p>
    <input id="text" placeholder="请输入影视名称..." />
    <button onclick="send()">发送</button>
    <div id="status"></div>
  </div>
  <script>
    function setStatus(msg, color) {
      const el = document.getElementById("status");
      el.textContent = msg;
      el.style.color = color || "#888";
    }
    function send() {
      const input = document.getElementById("text");
      const value = input.value.trim();
      if (!value) {
        setStatus("请输入内容", "#FF6B6B");
        return;
      }
      setStatus("发送中...", "#888");
      fetch("/message", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ message: value })
      })
      .then(r => r.json())
      .then(data => {
        if (data.status === "ok") {
          setStatus("发送成功", "#4CAF50");
          input.value = "";
        } else {
          setStatus("发送失败: " + (data.error || ""), "#FF6B6B");
        }
      })
      .catch(err => {
        setStatus("发送失败，请检查网络", "#FF6B6B");
      });
    }
    document.getElementById("text").addEventListener("keypress", function(e) {
      if (e.key === "Enter") send();
    });
  </script>
</body>
</html>
''';
  }

  Future<String> startServer({
    String currentServerUrl = '',
    String currentBackupServerUrl = '',
  }) async {
    if (_server != null) return _serverUrl!;

    try {
      _server = await HttpServer.bind(InternetAddress.anyIPv4, 0);
      final port = _server!.port;
      final ip = await _getLocalIp();
      _serverUrl = 'http://$ip:$port';

      _server!.listen((request) async {
        try {
          if (request.method == 'OPTIONS') {
            _setCorsHeaders(request.response);
            request.response
              ..statusCode = 204
              ..close();
            return;
          }
          if (request.method == 'GET' && request.uri.path == '/') {
            final loginMode = request.uri.queryParameters['mode'] == 'login';
            final serverConfigMode =
                request.uri.queryParameters['mode'] == 'server_config';
            final subAccountMode =
                request.uri.queryParameters['mode'] == 'sub_account';
            final html = _getRemotePageHTML(
              _serverUrl!,
              loginMode: loginMode,
              serverConfigMode: serverConfigMode,
              subAccountMode: subAccountMode,
              currentServerUrl: currentServerUrl,
              currentBackupServerUrl: currentBackupServerUrl,
            );
            _setCorsHeaders(request.response);
            request.response
              ..statusCode = 200
              ..headers.contentType = ContentType.html
              ..write(html)
              ..close();
          } else if (request.method == 'POST' &&
              request.uri.path == '/message') {
            final body = await utf8.decoder.bind(request).join();
            final data = jsonDecode(body) as Map<String, dynamic>;
            final message = data['message'] as String?;
            if (message != null && message.isNotEmpty) {
              _messageController.add(message);
            }
            _setCorsHeaders(request.response);
            request.response
              ..statusCode = 200
              ..headers.contentType = ContentType.json
              ..write(jsonEncode({'status': 'ok'}))
              ..close();
          } else if (request.method == 'POST' && request.uri.path == '/login') {
            final body = await utf8.decoder.bind(request).join();
            final data = jsonDecode(body) as Map<String, dynamic>;
            final serverUrl = (data['serverUrl'] as String?)?.trim() ?? '';
            final backupServerUrl =
                (data['backupServerUrl'] as String?)?.trim() ?? '';
            final username = (data['username'] as String?)?.trim() ?? '';
            final password = (data['password'] as String?)?.trim() ?? '';
            if ((serverUrl.isNotEmpty || backupServerUrl.isNotEmpty) &&
                password.isNotEmpty) {
              _loginController.add({
                'serverUrl': serverUrl,
                'backupServerUrl': backupServerUrl,
                'username': username,
                'password': password,
              });
              _setCorsHeaders(request.response);
              request.response
                ..statusCode = 200
                ..headers.contentType = ContentType.json
                ..write(jsonEncode({'status': 'ok'}))
                ..close();
            } else {
              _setCorsHeaders(request.response);
              request.response
                ..statusCode = 400
                ..headers.contentType = ContentType.json
                ..write(jsonEncode({'status': 'error', 'error': '缺少服务器地址或密码'}))
                ..close();
            }
          } else if (request.method == 'POST' &&
              request.uri.path == '/server_config') {
            final body = await utf8.decoder.bind(request).join();
            final data = jsonDecode(body) as Map<String, dynamic>;
            final serverUrl = (data['serverUrl'] as String?)?.trim() ?? '';
            final backupServerUrl =
                (data['backupServerUrl'] as String?)?.trim() ?? '';
            if (serverUrl.isNotEmpty || backupServerUrl.isNotEmpty) {
              _serverConfigController.add({
                'serverUrl': serverUrl,
                'backupServerUrl': backupServerUrl,
              });
              _setCorsHeaders(request.response);
              request.response
                ..statusCode = 200
                ..headers.contentType = ContentType.json
                ..write(jsonEncode({'status': 'ok'}))
                ..close();
            } else {
              _setCorsHeaders(request.response);
              request.response
                ..statusCode = 400
                ..headers.contentType = ContentType.json
                ..write(jsonEncode({'status': 'error', 'error': '缺少服务器地址'}))
                ..close();
            }
          } else if (request.method == 'POST' &&
              request.uri.path == '/sub_account') {
            final body = await utf8.decoder.bind(request).join();
            final data = jsonDecode(body) as Map<String, dynamic>;
            final username = (data['username'] as String?)?.trim() ?? '';
            final password = (data['password'] as String?)?.trim() ?? '';
            if (username.isNotEmpty && password.isNotEmpty) {
              _subAccountController.add({
                'username': username,
                'password': password,
              });
              _setCorsHeaders(request.response);
              request.response
                ..statusCode = 200
                ..headers.contentType = ContentType.json
                ..write(jsonEncode({'status': 'ok'}))
                ..close();
            } else {
              _setCorsHeaders(request.response);
              request.response
                ..statusCode = 400
                ..headers.contentType = ContentType.json
                ..write(jsonEncode({'status': 'error', 'error': '缺少用户名或密码'}))
                ..close();
            }
          } else {
            _setCorsHeaders(request.response);
            request.response
              ..statusCode = 404
              ..write('Not Found')
              ..close();
          }
        } catch (e) {
          _setCorsHeaders(request.response);
          request.response
            ..statusCode = 500
            ..write('Internal Server Error')
            ..close();
        }
      });

      return _serverUrl!;
    } catch (e) {
      stopServer();
      throw Exception('启动远程输入服务失败: $e');
    }
  }

  void stopServer() {
    _server?.close(force: true);
    _server = null;
    _serverUrl = null;
  }

  Future<String> _getLocalIp() async {
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLinkLocal: false,
      );
      for (final interface in interfaces) {
        for (final addr in interface.addresses) {
          if (!addr.isLoopback && addr.type == InternetAddressType.IPv4) {
            return addr.address;
          }
        }
      }
    } catch (e) {
      debugPrint('获取本地IP失败: $e');
    }
    return '127.0.0.1';
  }

  void dispose() {
    stopServer();
    // StreamController 为单例生命周期服务，不在 dispose 中关闭，
    // 否则退出登录后重新进入登录页时控制器已关闭，导致二维码登录无法触发。
  }
}
