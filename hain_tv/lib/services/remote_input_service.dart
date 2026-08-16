import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../models/live_source_config.dart';
import 'live_service.dart';
import 'live_source_storage.dart';

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
    response.headers.add('Access-Control-Allow-Methods', 'GET, POST, DELETE, OPTIONS');
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

  final _liveSourcesChangedController = StreamController<void>.broadcast();
  Stream<void> get onLiveSourcesChanged => _liveSourcesChangedController.stream;

  String _getLiveSourcesPageHTML(String serverUrl) {
    return '''
<!DOCTYPE html>
<html>
<head>
  <title>海因影视 - 管理电视直播源</title>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0, user-scalable=no">
  <style>
    body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, "Helvetica Neue", Arial, sans-serif; margin: 0; background-color: #121212; color: white; padding: 16px; box-sizing: border-box; }
    h3 { color: #eee; margin: 0 0 8px 0; }
    p { color: #888; font-size: 14px; margin: 0 0 16px 0; }
    .card { background-color: #1e1e1e; border-radius: 10px; padding: 12px; margin-bottom: 12px; }
    .card-header { display: flex; justify-content: space-between; align-items: center; margin-bottom: 8px; }
    .name { font-size: 15px; font-weight: 600; color: #fff; word-break: break-all; }
    .url { font-size: 12px; color: #888; word-break: break-all; margin-top: 4px; }
    .badge { display: inline-block; font-size: 11px; color: #E50914; border: 1px solid #E50914; border-radius: 4px; padding: 1px 6px; margin-left: 8px; }
    .actions { display: flex; gap: 8px; margin-top: 10px; }
    button { border: none; border-radius: 6px; padding: 8px 12px; font-size: 13px; cursor: pointer; }
    .btn-primary { background-color: #E50914; color: white; }
    .btn-primary:active { background-color: #b20710; }
    .btn-secondary { background-color: #333; color: white; }
    .btn-danger { background-color: #5c1a1a; color: #ff6b6b; }
    .field { margin-bottom: 12px; }
    label { display: block; color: #aaa; font-size: 13px; margin-bottom: 6px; }
    input, textarea { width: 100%; padding: 12px; font-size: 15px; border-radius: 8px; border: 1px solid #333; background-color: #2a2a2a; color: white; box-sizing: border-box; }
    textarea { min-height: 80px; resize: vertical; }
    #editor { display: none; margin-bottom: 16px; }
    #status { margin-top: 12px; font-size: 14px; color: #888; }
    .empty { text-align: center; color: #666; padding: 40px 0; }
  </style>
</head>
<body>
  <h3>电视直播源管理</h3>
  <p>在此添加、编辑或删除直播源，电视将自动同步</p>
  <div id="editor" class="card">
    <input type="hidden" id="editId" />
    <div class="field">
      <label>源名称</label>
      <input id="editName" placeholder="例如：央视卫视" />
    </div>
    <div class="field">
      <label>M3U/M3U8/JSON 地址或内容</label>
      <textarea id="editUrl" placeholder="支持网络地址或粘贴文本内容"></textarea>
    </div>
    <div class="actions">
      <button class="btn-primary" onclick="saveSource()">保存</button>
      <button class="btn-secondary" onclick="cancelEdit()">取消</button>
    </div>
  </div>
  <button class="btn-primary" id="addBtn" onclick="showAdd()" style="width:100%; margin-bottom:16px;">添加直播源</button>
  <div id="list"></div>
  <div id="status"></div>
  <script>
    let sources = [];
    function setStatus(msg, color) {
      const el = document.getElementById("status");
      el.textContent = msg;
      el.style.color = color || "#888";
    }
    async function loadSources() {
      try {
        const r = await fetch("/api/live_sources");
        const data = await r.json();
        sources = data.sources || [];
        renderList();
      } catch (e) {
        setStatus("加载失败，请检查网络", "#FF6B6B");
      }
    }
    function renderList() {
      const list = document.getElementById("list");
      const userSources = sources.filter(s => !s.isBuiltin);
      if (userSources.length === 0) {
        list.innerHTML = '<div class="empty">暂无自定义直播源，点击上方添加</div>';
        return;
      }
      list.innerHTML = userSources.map(s => `
        <div class="card">
          <div class="card-header">
            <span class="name">\${escapeHtml(s.name)}</span>
            \${s.enabled !== false ? '' : '<span class="badge">已禁用</span>'}
          </div>
          <div class="url">\${escapeHtml(s.url)}</div>
          <div class="actions">
            <button class="btn-secondary" onclick="editSource('\${s.id}')">编辑</button>
            <button class="btn-danger" onclick="deleteSource('\${s.id}')">删除</button>
          </div>
        </div>
      `).join('');
    }
    function escapeHtml(text) {
      const div = document.createElement('div');
      div.textContent = text;
      return div.innerHTML;
    }
    function showAdd() {
      document.getElementById("editId").value = "";
      document.getElementById("editName").value = "";
      document.getElementById("editUrl").value = "";
      document.getElementById("editor").style.display = "block";
      document.getElementById("addBtn").style.display = "none";
    }
    function editSource(id) {
      const s = sources.find(x => x.id === id);
      if (!s) return;
      document.getElementById("editId").value = s.id;
      document.getElementById("editName").value = s.name;
      document.getElementById("editUrl").value = s.url;
      document.getElementById("editor").style.display = "block";
      document.getElementById("addBtn").style.display = "none";
    }
    function cancelEdit() {
      document.getElementById("editor").style.display = "none";
      document.getElementById("addBtn").style.display = "block";
    }
    async function saveSource() {
      const id = document.getElementById("editId").value.trim();
      const name = document.getElementById("editName").value.trim();
      const url = document.getElementById("editUrl").value.trim();
      if (!name || !url) {
        setStatus("名称和地址不能为空", "#FF6B6B");
        return;
      }
      setStatus("保存中...", "#888");
      try {
        const existing = sources.find(s => s.id === id);
        const enabled = existing ? (existing.enabled !== false) : true;
        const r = await fetch("/api/live_sources", {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ id, name, url, enabled })
        });
        const data = await r.json();
        if (data.status === "ok") {
          setStatus("保存成功", "#4CAF50");
          cancelEdit();
          await loadSources();
        } else {
          setStatus("保存失败: " + (data.error || ""), "#FF6B6B");
        }
      } catch (e) {
        setStatus("保存失败，请检查网络", "#FF6B6B");
      }
    }
    async function deleteSource(id) {
      if (!confirm("确定删除该直播源吗？")) return;
      setStatus("删除中...", "#888");
      try {
        const r = await fetch("/api/live_sources?id=" + encodeURIComponent(id), { method: "DELETE" });
        const data = await r.json();
        if (data.status === "ok") {
          setStatus("删除成功", "#4CAF50");
          await loadSources();
        } else {
          setStatus("删除失败: " + (data.error || ""), "#FF6B6B");
        }
      } catch (e) {
        setStatus("删除失败，请检查网络", "#FF6B6B");
      }
    }
    loadSources();
  </script>
</body>
</html>
''';
  }

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
            final mode = request.uri.queryParameters['mode'] ?? '';
            if (mode == 'live_sources') {
              final html = _getLiveSourcesPageHTML(_serverUrl!);
              _setCorsHeaders(request.response);
              request.response
                ..statusCode = 200
                ..headers.contentType = ContentType.html
                ..write(html)
                ..close();
              return;
            }
            final loginMode = mode == 'login';
            final serverConfigMode = mode == 'server_config';
            final subAccountMode = mode == 'sub_account';
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
          } else if (request.uri.path == '/api/live_sources') {
            await _handleLiveSourcesRequest(request);
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

  Future<void> _handleLiveSourcesRequest(HttpRequest request) async {
    try {
      if (request.method == 'GET') {
        final sources = await LiveService.getAllSources();
        _setCorsHeaders(request.response);
        request.response
          ..statusCode = 200
          ..headers.contentType = ContentType.json
          ..write(jsonEncode({
            'status': 'ok',
            'sources': sources.map((e) => e.toJson()).toList(),
          }))
          ..close();
        return;
      }

      if (request.method == 'POST') {
        final body = await utf8.decoder.bind(request).join();
        final data = jsonDecode(body) as Map<String, dynamic>;
        final id = (data['id'] as String?)?.trim() ?? '';
        final name = (data['name'] as String?)?.trim() ?? '';
        final url = (data['url'] as String?)?.trim() ?? '';
        final enabled = data['enabled'] != false;

        if (name.isEmpty || url.isEmpty) {
          _setCorsHeaders(request.response);
          request.response
            ..statusCode = 400
            ..headers.contentType = ContentType.json
            ..write(jsonEncode({'status': 'error', 'error': '名称和地址不能为空'}))
            ..close();
          return;
        }

        if (id == LiveService.lunaTvBuiltinSourceId) {
          _setCorsHeaders(request.response);
          request.response
            ..statusCode = 403
            ..headers.contentType = ContentType.json
            ..write(jsonEncode({'status': 'error', 'error': '系统内置源不允许修改'}))
            ..close();
          return;
        }

        final existing = await LiveSourceStorage.getConfigs();
        final oldConfig = existing.cast<LiveSourceConfig?>().firstWhere(
              (c) => c!.id == id,
              orElse: () => null,
            );
        final config = oldConfig != null
            ? oldConfig.copyWith(name: name, url: url, enabled: enabled)
            : LiveSourceConfig(
                id: LiveSourceConfig.generateId(),
                name: name,
                url: url,
                isLocal: true,
                enabled: enabled,
                createTime: DateTime.now(),
              );
        await LiveSourceStorage.saveConfig(config);
        _liveSourcesChangedController.add(null);
        _setCorsHeaders(request.response);
        request.response
          ..statusCode = 200
          ..headers.contentType = ContentType.json
          ..write(jsonEncode({'status': 'ok'}))
          ..close();
        return;
      }

      if (request.method == 'DELETE') {
        final id = request.uri.queryParameters['id'];
        if (id == null || id.isEmpty) {
          _setCorsHeaders(request.response);
          request.response
            ..statusCode = 400
            ..headers.contentType = ContentType.json
            ..write(jsonEncode({'status': 'error', 'error': '缺少直播源 ID'}))
            ..close();
          return;
        }
        if (id == LiveService.lunaTvBuiltinSourceId) {
          _setCorsHeaders(request.response);
          request.response
            ..statusCode = 403
            ..headers.contentType = ContentType.json
            ..write(jsonEncode({'status': 'error', 'error': '系统内置源不允许删除'}))
            ..close();
          return;
        }
        await LiveSourceStorage.deleteConfig(id);
        _liveSourcesChangedController.add(null);
        _setCorsHeaders(request.response);
        request.response
          ..statusCode = 200
          ..headers.contentType = ContentType.json
          ..write(jsonEncode({'status': 'ok'}))
          ..close();
        return;
      }

      _setCorsHeaders(request.response);
      request.response
        ..statusCode = 405
        ..headers.contentType = ContentType.json
        ..write(jsonEncode({'status': 'error', 'error': '不支持的请求方法'}))
        ..close();
    } catch (e) {
      _setCorsHeaders(request.response);
      request.response
        ..statusCode = 500
        ..headers.contentType = ContentType.json
        ..write(jsonEncode({'status': 'error', 'error': '服务器内部错误: $e'}))
        ..close();
    }
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
