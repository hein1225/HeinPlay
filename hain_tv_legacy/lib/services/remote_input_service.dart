import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../models/live_source_config.dart';
import 'ad_filter_service.dart';
import 'cache_service.dart';
import 'global_ui_refresh_notifier.dart';
import 'hain_tv_cache_manager.dart';
import 'live_service.dart';
import 'live_source_refresh_notifier.dart';
import 'live_source_storage.dart';
import '../player/player_backend_factory.dart';
import '../platform/device_utils.dart';
import 'server_latency_service.dart';
import 'settings_schema.dart';
import 'theme_mode_service.dart';
import 'user_data_service.dart';
import '../utils/app_logger.dart';

class RemoteInputService {
  static final RemoteInputService _instance = RemoteInputService._internal();
  factory RemoteInputService() => _instance;
  RemoteInputService._internal();

  HttpServer? _server;
  String? _serverUrl;

  /// 最近一次手机下发的搜索关键词（缓冲）：当 TV 搜索页尚未打开时先暂存，
  /// 待 SearchScreen 打开后取出并直接搜索，避免关键词随广播流丢失。
  String? _pendingSearchKeyword;

  bool get isRunning => _server != null;
  String? get serverUrl => _serverUrl;

  /// 取出并清空缓冲的搜索关键词（仅在搜索页刚打开时调用一次，用于补触发搜索）。
  String? takePendingSearchKeyword() {
    final v = _pendingSearchKeyword;
    _pendingSearchKeyword = null;
    return v;
  }

  /// 清除缓冲的搜索关键词（搜索页已在前台接收后调用，避免下次打开时误触发）。
  void clearPendingSearchKeyword() {
    _pendingSearchKeyword = null;
  }

  /// 统一手机设置页地址：固定端口 + ?mode=settings，无论从任何入口扫码都进入同一页。
  String? get settingsUrl =>
      _serverUrl == null ? null : '$_serverUrl?mode=settings';

  /// 统一手机管理页地址，并跳转到指定分类（如 search/account/server/live_sources）。
  /// 所有二维码扫码入口都应走此方法，保证进入同一个整合管理页的对应分类，
  /// 而不是各自一套独立页面（部分独立页面会一直停在“加载中”）。
  String? settingsUrlWithCat(String cat) =>
      settingsUrl == null ? null : '$settingsUrl&cat=$cat';

  /// 首次登录专用手机页地址（常驻 5025 上的独立登录表单页）：手机扫码后输入
  /// 服务器/用户名/密码，电视自动登录。登录成功后页面转为「已登录」态不再提供登录，
  /// 与子账号管理（cat=account）区分——首次登录时主账号尚未配置，应进入本登录表单页。
  String? get settingsLoginUrl =>
      _serverUrl == null ? null : '$_serverUrl?mode=login';

  void _setCorsHeaders(HttpResponse response) {
    response.headers.add('Access-Control-Allow-Origin', '*');
    response.headers.add('Access-Control-Allow-Methods', 'GET, POST, DELETE, OPTIONS');
    response.headers.add('Access-Control-Allow-Headers', 'Content-Type');
  }

  final _messageController = StreamController<String>.broadcast();
  Stream<String> get onMessage => _messageController.stream;

  /// 手机端「扫码登录」结果处理器：由 TV 登录页注册。服务端 /login 接口
  /// await 其返回值，把 TV 端真实登录结果（含错误信息）回传给手机登录页。
  Future<Map<String, dynamic>> Function(Map<String, dynamic>)? _loginHandler;
  void setLoginHandler(Future<Map<String, dynamic>> Function(Map<String, dynamic>)? h) =>
      _loginHandler = h;

  final _serverConfigController =
      StreamController<Map<String, String>>.broadcast();
  Stream<Map<String, String>> get onServerConfig =>
      _serverConfigController.stream;

  /// 手机端子账号保存/切换结果处理器：由 TvShell 注册。服务端 /sub_account
  /// 接口 await 其返回值，把真实结果（含错误）回传给手机页。
  Future<Map<String, dynamic>> Function(Map<String, dynamic>)? _subAccountHandler;
  void setSubAccountHandler(
          Future<Map<String, dynamic>> Function(Map<String, dynamic>)? h) =>
      _subAccountHandler = h;

  final _liveSourcesChangedController = StreamController<void>.broadcast();
  Stream<void> get onLiveSourcesChanged => _liveSourcesChangedController.stream;

  /// 统一手机设置页「搜索」命令：手机点击后 TV 自动跳到搜索页开始搜索。
  final _searchCommandController = StreamController<void>.broadcast();
  Stream<void> get onSearchCommand => _searchCommandController.stream;

  /// 手机账号管理命令结果处理器：由 TvShell 注册。服务端 /api/command/account
  /// await 其返回值，把切换/删除/退出等真实结果（含错误）回传给手机页。
  Future<Map<String, dynamic>> Function(Map<String, dynamic>)? _accountActionHandler;
  void setAccountActionHandler(
          Future<Map<String, dynamic>> Function(Map<String, dynamic>)? h) =>
      _accountActionHandler = h;

  /// 账号数据（子账号/激活态）变化后广播，供账号管理页刷新 UI。
  /// 手机端输入子账号或执行切换/删除/退出等动作后，由 tv_shell 统一处理后触发，
  /// 与手机来源解耦，避免账号页仅在自身打开时才响应。
  final _accountsChangedController = StreamController<void>.broadcast();
  Stream<void> get onAccountsChanged => _accountsChangedController.stream;
  void notifyAccountsChanged() => _accountsChangedController.add(null);

  /// 等待 UI 层注册的账号操作处理器返回结果（含超时保护），用于把 TV 端
  /// 真实处理结果（成功或错误信息）回传给手机页。未注册处理器或非预期异常时返回错误态。
  Future<Map<String, dynamic>> _awaitHandlerResult(
    Future<Map<String, dynamic>> Function(Map<String, dynamic>)? handler,
    Map<String, dynamic> data,
  ) async {
    if (handler == null) {
      return {'status': 'error', 'error': '电视端暂未就绪，请稍后重试'};
    }
    try {
      return await handler(data).timeout(const Duration(seconds: 30));
    } on TimeoutException {
      return {'status': 'error', 'error': '电视端处理超时，请重试'};
    } catch (e) {
      return {'status': 'error', 'error': e.toString()};
    }
  }

  /// 手机服务器管理命令流：手机点击「立即测试切换」后，TV 端服务器管理页实时刷新。
  /// 事件体：`{'action': 'speedtest'}`。
  final _serverActionController =
      StreamController<Map<String, dynamic>>.broadcast();
  Stream<Map<String, dynamic>> get onServerAction =>
      _serverActionController.stream;

  /// 设备名称，用于局域网发现时向手机展示（如「客厅电视」）。
  String _deviceName = '海因影视 TV';
  String get deviceName => _deviceName;
  set deviceName(String value) {
    _deviceName = value.isNotEmpty ? value : '海因影视 TV';
  }

  /// TV 当前播放状态提供器：由播放页注册，供手机轮询进度。
  /// 返回 {title, positionMs, durationMs, source} 或 null（无播放）。
  Future<Map<String, dynamic>> Function()? playbackStatusProvider;

  /// 控制端口，统一手机控制与设置页的发现入口。
  static const int controlPort = 5025;

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
    .group-title { color: #00C8E0; font-size: 13px; font-weight: 600; margin: 16px 2px 8px; }
    .card { background-color: #1e1e1e; border-radius: 10px; padding: 12px; margin-bottom: 12px; }
    .card-header { display: flex; justify-content: space-between; align-items: center; margin-bottom: 8px; }
    .name { font-size: 15px; font-weight: 600; color: #fff; word-break: break-all; }
    .url { font-size: 12px; color: #888; word-break: break-all; margin-top: 4px; }
    .badge { display: inline-block; font-size: 11px; color: #00C8E0; border: 1px solid #00C8E0; border-radius: 4px; padding: 1px 6px; margin-left: 8px; }
    .badge-disable { display: inline-block; font-size: 11px; color: #ff6b6b; border: 1px solid #ff6b6b; border-radius: 4px; padding: 1px 6px; margin-left: 8px; }
    .actions { display: flex; gap: 8px; margin-top: 10px; flex-wrap: wrap; }
    button { border: none; border-radius: 6px; padding: 8px 12px; font-size: 13px; cursor: pointer; }
    .btn-primary { background-color: #00C8E0; color: white; }
    .btn-primary:active { background-color: #0098B0; }
    .btn-secondary { background-color: #333; color: white; }
    .btn-danger { background-color: #5c1a1a; color: #ff6b6b; }
    .btn-ghost { background-color: #2a2a2a; color: #ccc; }
    .btn-updown { background-color: #2a2a2a; color: #00C8E0; min-width: 40px; }
    .btn-updown:disabled { color: #555; background-color: #1a1a1a; cursor: not-allowed; }
    .field { margin-bottom: 12px; }
    label { display: block; color: #aaa; font-size: 13px; margin-bottom: 6px; }
    input, textarea { width: 100%; padding: 12px; font-size: 15px; border-radius: 8px; border: 1px solid #333; background-color: #2a2a2a; color: white; box-sizing: border-box; }
    textarea { min-height: 80px; resize: vertical; }
    #editor { display: none; margin-bottom: 16px; }
    #status { margin-top: 12px; font-size: 14px; color: #888; }
    .empty { text-align: center; color: #666; padding: 20px 0; }
  </style>
</head>
<body>
  <h3>电视直播源管理</h3>
  <p>显示 LunaTV 服务器直播源与本地直播源，可分段排序与清除缓存</p>
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
  <button class="btn-primary" id="addBtn" onclick="showAdd()" style="width:100%; margin-bottom:16px;">添加本地直播源</button>
  <div id="list"></div>
  <div id="status"></div>
  <script>
    let sources = [];
    function esc(t) {
      if (t == null) return "";
      return String(t).replace(/&/g,"&amp;").replace(/</g,"&lt;").replace(/>/g,"&gt;").replace(/'/g,"&#039;");
    }
    function escapeHtml(text) {
      const div = document.createElement('div');
      div.textContent = text;
      return div.innerHTML;
    }
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
      const builtins = sources.filter(s => s.isBuiltin);
      const locals = sources.filter(s => !s.isBuiltin);
      let html = '';
      if (builtins.length === 0 && locals.length === 0) {
        list.innerHTML = '<div class="empty">暂无直播源</div>';
        return;
      }
      if (builtins.length > 0) {
        html += '<div class="group-title">LunaTV 服务器直播源</div>';
        builtins.forEach(function(s, i) {
          html += itemHtml(s, i, builtins.length, true);
        });
      }
      if (locals.length > 0) {
        html += '<div class="group-title">本地直播源</div>';
        locals.forEach(function(s, i) {
          html += itemHtml(s, i, locals.length, false);
        });
      }
      list.innerHTML = html;
    }
    function itemHtml(s, i, total, isBuiltin) {
      const disabled = s.enabled === false ? '<span class="badge-disable">已禁用</span>' : '';
      const isLocal = !isBuiltin;
      const upDisabled = i === 0 ? 'disabled' : '';
      const downDisabled = i === total - 1 ? 'disabled' : '';
      return '<div class="card" data-id="' + esc(s.id) + '" data-builtin="' + (isBuiltin ? '1' : '0') + '">'
        + '<div class="card-header"><span class="name">' + escapeHtml(s.name) + (isBuiltin ? '<span class="badge">服务器</span>' : '') + disabled + '</span></div>'
        + '<div class="url">' + escapeHtml(s.url) + '</div>'
        + '<div class="actions">'
        + '<button class="btn-updown" ' + upDisabled + ' onclick="moveSource(\\'' + esc(s.id) + '\\', \\'up\\')">▲</button>'
        + '<button class="btn-updown" ' + downDisabled + ' onclick="moveSource(\\'' + esc(s.id) + '\\', \\'down\\')">▼</button>'
        + '<button class="btn-ghost" onclick="clearCache(\\'' + esc(s.id) + '\\')">清除缓存</button>'
        + (isLocal ? '<button class="btn-secondary" onclick="editSource(\\'' + esc(s.id) + '\\')">编辑</button><button class="btn-danger" onclick="deleteSource(\\'' + esc(s.id) + '\\')">删除</button>' : '')
        + '</div></div>';
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
    async function moveSource(id, direction) {
      try {
        const r = await fetch("/api/live_sources/reorder", {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ id: id, direction: direction })
        });
        const data = await r.json();
        if (data.status === "ok") { await loadSources(); }
        else { setStatus("排序失败: " + (data.error || ""), "#FF6B6B"); }
      } catch (e) {
        setStatus("排序失败，请检查网络", "#FF6B6B");
      }
    }
    async function clearCache(id) {
      if (!confirm("确定清除该直播源缓存吗？")) return;
      setStatus("清除缓存中...", "#888");
      try {
        const r = await fetch("/api/live_sources/clear_cache", {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ id: id })
        });
        const data = await r.json();
        setStatus(data.status === "ok" ? "缓存已清除" : ("失败: " + (data.error || "")), data.status === "ok" ? "#4CAF50" : "#FF6B6B");
      } catch (e) {
        setStatus("清除失败，请检查网络", "#FF6B6B");
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
    bool alreadyLoggedIn = false,
    String currentServerUrl = '',
    String currentBackupServerUrl = '',
  }) {
    if (loginMode) {
      // 已登录时不再显示登录表单，仅提示已登录（二维码首次登录场景的「登录后不再显示」）。
      if (alreadyLoggedIn) {
        return '''
<!DOCTYPE html>
<html>
<head>
  <title>海因影视 - 已登录</title>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0, user-scalable=no">
  <style>
    body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, "Helvetica Neue", Arial, sans-serif; display: flex; flex-direction: column; align-items: center; justify-content: center; min-height: 100vh; margin: 0; background-color: #121212; color: white; padding: 20px; box-sizing: border-box; text-align: center; }
    .ok { font-size: 56px; margin-bottom: 16px; }
    h3 { color: #4CAF50; margin-bottom: 8px; }
    p { color: #888; font-size: 14px; }
  </style>
</head>
<body>
  <div class="ok">✅</div>
  <h3>电视已登录</h3>
  <p>当前账号已登录，无需再次扫码登录。<br>如需管理子账号或切换主题，请用管理页二维码。</p>
  <p id="cd" style="margin-top:18px;color:#00C8E0;">10 秒后自动跳转到管理页…</p>
  <script>
    var n = 10;
    var t = setInterval(function() {
      n = n - 1;
      var el = document.getElementById('cd');
      if (n <= 0) { clearInterval(t); location.href = '$serverUrl?mode=settings'; }
      else if (el) { el.textContent = n + ' 秒后自动跳转到管理页…'; }
    }, 1000);
  </script>
</body>
</html>
''';
      }
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
    button { width: 100%; padding: 15px; font-size: 18px; font-weight: bold; border: none; border-radius: 8px; background-color: #00C8E0; color: white; cursor: pointer; }
    button:active { background-color: #0098B0; }
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
      <label>用户名</label>
      <input id="username" placeholder="数据库模式需填写，其他模式可留空" />
    </div>
    <div class="field">
      <label>密码</label>
      <input id="password" type="password" placeholder="LunaTV 登录密码" />
    </div>
    <button onclick="sendLogin()">登录</button>
    <div id="status"></div>
  </div>
  <script>
    function esc(t) {
      if (t == null) return "";
      return String(t).replace(/&/g,"&amp;").replace(/</g,"&lt;").replace(/>/g,"&gt;").replace(/'/g,"&#039;");
    }
    function _showInitError(e) {
      var p = document.getElementById("panel");
      var body = document.body;
      var html = "<h2>页面加载失败</h2><div class='card'><div class='label'>" + esc(e && e.name ? e.name : "初始化错误") + "</div><div class='hint'>" + esc(e && e.message ? e.message : String(e)) + "</div><div class='hint'>" + esc(e && e.stack ? e.stack : "") + "</div></div>";
      if (p) p.innerHTML = html;
      else if (body) body.innerHTML = "<div style='padding:20px;color:#fff;background:#121212;'>" + html + "</div>";
    }
    window.onerror = function(msg, url, line, col, err) {
      _showInitError(err || {message: (msg || "") + " @行" + line + ":列" + col});
    };
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
          // 登录成功后页面自动刷新为「已登录」态，不再提供登录表单。
          setTimeout(function(){ location.reload(); }, 1200);
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
    button { width: 100%; padding: 15px; font-size: 18px; font-weight: bold; border: none; border-radius: 8px; background-color: #00C8E0; color: white; cursor: pointer; }
    button:active { background-color: #0098B0; }
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
    function esc(t) {
      if (t == null) return "";
      return String(t).replace(/&/g,"&amp;").replace(/</g,"&lt;").replace(/>/g,"&gt;").replace(/'/g,"&#039;");
    }
    function _showInitError(e) {
      var p = document.getElementById("panel");
      var body = document.body;
      var html = "<h2>页面加载失败</h2><div class='card'><div class='label'>" + esc(e && e.name ? e.name : "初始化错误") + "</div><div class='hint'>" + esc(e && e.message ? e.message : String(e)) + "</div><div class='hint'>" + esc(e && e.stack ? e.stack : "") + "</div></div>";
      if (p) p.innerHTML = html;
      else if (body) body.innerHTML = "<div style='padding:20px;color:#fff;background:#121212;'>" + html + "</div>";
    }
    window.onerror = function(msg, url, line, col, err) {
      _showInitError(err || {message: (msg || "") + " @行" + line + ":列" + col});
    };
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
    button { width: 100%; padding: 15px; font-size: 18px; font-weight: bold; border: none; border-radius: 8px; background-color: #00C8E0; color: white; cursor: pointer; }
    button:active { background-color: #0098B0; }
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
    function esc(t) {
      if (t == null) return "";
      return String(t).replace(/&/g,"&amp;").replace(/</g,"&lt;").replace(/>/g,"&gt;").replace(/'/g,"&#039;");
    }
    function _showInitError(e) {
      var p = document.getElementById("panel");
      var body = document.body;
      var html = "<h2>页面加载失败</h2><div class='card'><div class='label'>" + esc(e && e.name ? e.name : "初始化错误") + "</div><div class='hint'>" + esc(e && e.message ? e.message : String(e)) + "</div><div class='hint'>" + esc(e && e.stack ? e.stack : "") + "</div></div>";
      if (p) p.innerHTML = html;
      else if (body) body.innerHTML = "<div style='padding:20px;color:#fff;background:#121212;'>" + html + "</div>";
    }
    window.onerror = function(msg, url, line, col, err) {
      _showInitError(err || {message: (msg || "") + " @行" + line + ":列" + col});
    };
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
    button { width: 100%; padding: 15px; font-size: 18px; font-weight: bold; border: none; border-radius: 8px; background-color: #00C8E0; color: white; cursor: pointer; }
    button:active { background-color: #0098B0; }
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
    function esc(t) {
      if (t == null) return "";
      return String(t).replace(/&/g,"&amp;").replace(/</g,"&lt;").replace(/>/g,"&gt;").replace(/'/g,"&#039;");
    }
    function _showInitError(e) {
      var p = document.getElementById("panel");
      var body = document.body;
      var html = "<h2>页面加载失败</h2><div class='card'><div class='label'>" + esc(e && e.name ? e.name : "初始化错误") + "</div><div class='hint'>" + esc(e && e.message ? e.message : String(e)) + "</div><div class='hint'>" + esc(e && e.stack ? e.stack : "") + "</div></div>";
      if (p) p.innerHTML = html;
      else if (body) body.innerHTML = "<div style='padding:20px;color:#fff;background:#121212;'>" + html + "</div>";
    }
    window.onerror = function(msg, url, line, col, err) {
      _showInitError(err || {message: (msg || "") + " @行" + line + ":列" + col});
    };
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

  List<Map<String, String>> _backendOptionsJson(
    List<PlayerBackendType> backends,
    PlayerBackendType platformDefault,
  ) {
    const titles = {
      PlayerBackendType.exo: 'ExoPlayer',
      PlayerBackendType.fvp: 'FVP',
      PlayerBackendType.vlc: 'VLC',
    };
    const subtitles = {
      PlayerBackendType.exo: 'Android 原生播放器，硬解能力强',
      PlayerBackendType.fvp: '基于 libmdk，兼容性较好',
      PlayerBackendType.vlc: '基于 libvlc，格式兼容性最强',
    };
    return backends.map((t) {
      final isDefault = t == platformDefault;
      final title = titles[t]! + (isDefault ? '（默认）' : '');
      return {'value': t.name, 'title': title, 'subtitle': subtitles[t]!};
    }).toList();
  }

  Future<String> _getSettingsPageHTML(String serverUrl) async {
    Map<String, dynamic> snapshot;
    try {
      snapshot = await _currentSettingsSnapshot();
    } catch (e) {
      snapshot = <String, dynamic>{};
    }
    List<Map<String, String>> vodBackends;
    List<Map<String, String>> liveBackends;
    try {
      vodBackends = _backendOptionsJson(
        PlayerBackendFactory.availableBackends,
        PlayerBackendFactory.platformDefault,
      );
      liveBackends = _backendOptionsJson(
        PlayerBackendFactory.availableBackends,
        PlayerBackendFactory.platformLiveDefault,
      );
    } catch (e) {
      vodBackends = const [
        <String, String>{'value': 'fvp', 'title': 'FVP（默认）'}
      ];
      liveBackends = vodBackends;
    }
    final isWindows = DeviceUtils.isComputer;

    final DOUBAN_OPTIONS = const <Map<String, String>>[
      const {'value': 'direct', 'title': '直连（默认）', 'subtitle': '直接访问豆瓣官方接口'},
      const {'value': 'cdnTencent', 'title': '腾讯云 CDN', 'subtitle': '通过腾讯云 CDN 加速访问'},
      const {'value': 'cdnAliyun', 'title': '阿里云 CDN', 'subtitle': '通过阿里云 CDN 加速访问'},
      const {'value': 'corsProxy', 'title': 'CORS 代理', 'subtitle': '通过 CORS 代理服务器访问'},
    ];
    final BANGUMI_API_OPTIONS = const <Map<String, String>>[
      const {'value': 'direct', 'title': '直连（直接访问 api.bgm.tv）', 'subtitle': ''},
      const {'value': 'cmliussss', 'title': 'Bangumi 反代 By CMLiussss（解决服务器被墙）', 'subtitle': ''},
      const {'value': 'custom', 'title': '自定义反代地址', 'subtitle': ''},
    ];
    final BANGUMI_IMG_OPTIONS = const <Map<String, String>>[
      const {'value': 'direct', 'title': '直连（直接请求 lain.bgm.tv）', 'subtitle': ''},
      const {'value': 'cmliussss', 'title': 'Bangumi 图片 CDN By CMLiussss', 'subtitle': ''},
      const {'value': 'custom', 'title': '自定义代理', 'subtitle': ''},
    ];
    final CACHE_OPTIONS = const <Map<String, String>>[
      const {'value': '24', 'title': '1 天', 'subtitle': '默认缓存时间'},
      const {'value': '48', 'title': '2 天', 'subtitle': '48小时缓存'},
      const {'value': '72', 'title': '3 天', 'subtitle': '72小时缓存'},
      const {'value': '168', 'title': '7 天', 'subtitle': '最长缓存时间'},
    ];
    final BUFFER_PROFILE_OPTIONS = const <Map<String, String>>[
      const {'value': 'standard', 'title': '标准', 'subtitle': '常规缓冲策略，兼顾流畅与延迟'},
      const {'value': 'enhanced', 'title': '增强', 'subtitle': '更大缓冲，弱网环境更稳'},
      const {'value': 'power', 'title': '强力', 'subtitle': '最大缓冲，优先保证不卡顿'},
      const {'value': 'lowLatency', 'title': '低延迟', 'subtitle': '最小缓冲，直播/实时更跟手'},
    ];
    final AUTO_SWITCH_TIMEOUT_OPTIONS = const <Map<String, String>>[
      const {'value': '10', 'title': '10 秒', 'subtitle': '默认较短等待时间'},
      const {'value': '15', 'title': '15 秒', 'subtitle': '适中等待时间'},
      const {'value': '30', 'title': '30 秒', 'subtitle': '较长等待时间，适合弱网或源响应慢'},
    ];

    String esc(String? s) {
      if (s == null) return '';
      return s
          .replaceAll('&', '&amp;')
          .replaceAll('<', '&lt;')
          .replaceAll('>', '&gt;')
          .replaceAll('"', '&quot;');
    }

    String section(String t) => "<div class='section-title'>${esc(t)}</div>";
    String _h2(String t) => "<h2>${esc(t)}</h2>";
    String sw(String g, String k, String t, String h, bool v) =>
        "<div class='row'><div class='row-label'><div class='label'>${esc(t)}</div>${h.isNotEmpty ? "<div class='hint'>${esc(h)}</div>" : ""}</div><label class='switch'><input type='checkbox' ${v ? 'checked' : ''} onchange=\"applySetting('$g','$k',this.checked)\"><span class='slider'></span></label></div>";
    String radio(String g, String k, String t, List<Map<String, String>> opts, String v) {
      var h = "<div class='card'><div class='card-title'>${esc(t)}</div>";
      for (final o in opts) {
        final sel = (o['value'] ?? '') == v;
        final sub = o['subtitle'] ?? '';
        h += "<div class='opt ${sel ? 'sel' : ''}' onclick=\"applySetting('$g','$k','${esc(o['value'])}', this)\"><div><div class='opt-label'>${esc(o['title'])}</div>${sub.isNotEmpty ? "<div class='hint'>${esc(sub)}</div>" : ''}</div><span class='check'>${sel ? '✓' : ''}</span></div>";
      }
      return h + "</div>";
    }
    String txt(String g, String k, String t, String h, String v, String ph) =>
        "<div class='field'><label>${esc(t)}</label>${h.isNotEmpty ? "<div class='hint' style='margin-bottom:6px;'>${esc(h)}</div>" : ''}<input id='txt_${esc(k)}' value='${esc(v)}' placeholder='${esc(ph)}'><button class='primary' onclick=\"applySetting('$g','$k',document.getElementById('txt_${esc(k)}').value)\">保存</button></div>";
    String action(String id, String t, String h) =>
        "<div class='card action-card' onclick=\"runCommand('$id')\"><div><div class='label'>${esc(t)}</div>${h.isNotEmpty ? "<div class='hint'>${esc(h)}</div>" : ''}</div><span class='arrow'>›</span></div>";
    String actionAcc(String id, String t, String h) =>
        "<div class='card action-card' onclick=\"accountCommand('$id')\"><div><div class='label'>${esc(t)}</div>${h.isNotEmpty ? "<div class='hint'>${esc(h)}</div>" : ''}</div><span class='arrow'>›</span></div>";

    final vod = (snapshot['vod'] as Map?) ?? <String, dynamic>{};
    final live = (snapshot['live'] as Map?) ?? <String, dynamic>{};
    final data = (snapshot['data'] as Map?) ?? <String, dynamic>{};
    final theme = (snapshot['theme'] as Map?) ?? <String, dynamic>{};
    final other = (snapshot['other'] as Map?) ?? <String, dynamic>{};
    final server = (snapshot['server'] as Map?) ?? <String, dynamic>{};
    final account = (snapshot['account'] as Map?) ?? <String, dynamic>{};

    String catHome() {
      final intro = "海因影视是一款基于 Flutter 开发的跨平台影视应用，TV 版支持多源播放、豆瓣数据展示等功能。手机版与 Windows 版本可前往下方开源仓库下载。";
      var h = "<div class='card'><div class='label'>软件介绍</div><div class='hint' style='line-height:1.6;'>${esc(intro)}</div></div>";
      h += "<div class='card'><div class='label'>下载与开源</div><div class='hint'>手机版 / Windows 版下载与源码：</div><a class='link' href='https://gitcode.com/gcw_QbmhmbO8/HeinPlay' target='_blank'>国内仓库（GitCode）</a><a class='link' href='https://github.com/hein1225/HeinPlay' target='_blank'>GitHub 仓库</a></div>";
      return h;
    }

    String catSearch() =>
        "<div class='field'><label>搜索关键词</label><input id='kw' placeholder='输入影视名，电视端将自动跳转并搜索'><button class='primary' onclick='phoneSearch()'>搜索</button></div><div class='card'><div class='label'>说明</div><div class='hint'>在上方输入关键词并点击「搜索」，电视端会自动打开搜索页并开始搜索。</div></div>";
    String catAccount() {
      final su = account['subUsername']?.toString() ?? '';
      final subConfigured = account['subConfigured'] == true;
      final active = account['active']?.toString() == 'sub';
      var h = "<div class='card'><div class='label'>当前账号</div>";
      if (subConfigured) {
        h += "<div class='hint'>子账号：${esc(su)}</div>";
        h += "<div class='hint'>当前使用：${active ? '子账号' : '主账号'}</div>";
      } else {
        h += "<div class='hint'>尚未配置子账号</div>";
      }
      h += "</div>";
      if (subConfigured) {
        h += "<div class='card'><div class='label'>账号切换</div>";
        if (!active) {
          h += actionAcc("switch_sub", "切换为子账号",
              "切换到已保存的子账号，电视实时响应");
        } else {
          h += actionAcc("switch_main", "切换为主账号",
              "切回主账号，电视实时响应");
        }
        h += actionAcc("delete_sub", "删除子账号",
            "删除本地保存的子账号信息（若正在使用则回退主账号）");
        h += "</div>";
        h += "<div class='card'><div class='label'>修改子账号</div><div class='hint'>点下方按钮可修改已保存的子账号</div><button class='primary' onclick='toggleSubEdit()'>修改子账号</button><div id='subEdit' style='display:none;margin-top:10px;'><div class='field'><input id='su' placeholder='用户名' value='${esc(su)}'></div><div class='field'><input id='sp' type='password' placeholder='密码'></div><button class='primary' onclick='sendSub()'>保存并切换</button></div></div>";
      } else {
        h += "<div class='card'><div class='label'>配置子账号</div><div class='hint'>填写用户名和密码后保存，电视将切换为该子账号</div><div class='field'><input id='su' placeholder='用户名' value='${esc(su)}'></div><div class='field'><input id='sp' type='password' placeholder='密码'></div><button class='primary' onclick='sendSub()'>保存并切换</button></div>";
      }
      h += actionAcc("logout", "退出登录", "清除本地登录信息并返回登录页");
      return h;
    }
    String catServer() =>
        section("服务器地址") +
        txt("server", "internetUrl", "互联网服务器地址", "", (server['serverUrl']?.toString() ?? ""), "") +
        txt("server", "backupUrl", "局域网/备用服务器地址（选填）", "", (server['backupServerUrl']?.toString() ?? ""), "") +
        section("连接策略") +
        sw("server", "autoSelectLowLatency", "自动选择低延迟服务器", "优先连接延迟更低的服务器节点", server['autoSelectLowLatency'] == true) +
        sw("server", "preferIpv6", "优先使用 IPv6", "在支持时优先通过 IPv6 连接", server['preferIpv6'] == true) +
        section("维护") +
        action("server_speedtest", "立即测试并切换", "手动测试服务器延迟并切换到最优地址，电视实时响应");
    String catVod() =>
        section("点播设置") +
        radio("vod", "playerBackend", "点播源默认播放器", vodBackends, (vod['playerBackend']?.toString() ?? "")) +
        sw("vod", "autoSkip", "自动跳过片头片尾", "到达片头/片尾区域时自动跳转", vod['autoSkip'] == true) +
        sw("vod", "autoPlayNext", "自动播放下一集", "片尾结束后自动播放下一集", vod['autoPlayNext'] == true) +
        sw("vod", "autoSpeedTest", "进入详情页自动测速", "多源时自动测试各源速度并排序，关闭后仍支持手动测速", vod['autoSpeedTest'] == true) +
        sw("vod", "autoSwitchSource", "播放失败自动切换播放源", "当前源无法播放时按测速顺序自动尝试其他源", vod['autoSwitchSource'] == true) +
        radio("vod", "autoSwitchSourceTimeout", "自动换源超时时间", AUTO_SWITCH_TIMEOUT_OPTIONS, (vod['autoSwitchSourceTimeout']?.toString() ?? "15")) +
        txt("vod", "m3u8ProxyUrl", "M3U8 代理地址", "配置后 M3U8/HLS 播放地址将通过代理请求，用于解决跨域或 Referer 限制", (vod['m3u8ProxyUrl']?.toString() ?? ""), "例如 http://127.0.0.1:8080/proxy?url=") +
        sw("vod", "adFilter", "M3U8 去广告（本地过滤）", "播放 M3U8 时使用本地规则过滤片头贴片广告", vod['adFilter'] == true) +
        sw("vod", "hardwareDecoding", "硬件解码", "关闭后可能解决部分花屏问题", vod['hardwareDecoding'] == true) +
        radio("vod", "bufferProfile", "缓冲模式", BUFFER_PROFILE_OPTIONS, (vod['bufferProfile']?.toString() ?? "standard"));
    String catLive() {
      var h = section("换台优化") +
          sw("live", "seamlessSwitch", "无缝换台", "开启后换台时当前画面继续播放，目标频道在后台预载，就绪后再切换", live['seamlessSwitch'] == true) +
          sw("live", "fcc", "FCC 快速换台", "开启后优先使用直播源提供的 FCC 地址拉流，缩短换台等待", live['fcc'] == true);
      h += section("直播设置") +
          sw("live", "localProxy", "本地 M3U8 代理", "开启后直播 M3U8 经本地代理转发，用于排查/兼容个别直播源", live['localProxy'] == true) +
          radio("live", "livePlayerBackend", "直播默认播放器", liveBackends, (live['livePlayerBackend']?.toString() ?? "")) +
          sw("live", "lunaTvEnabled", "启用 LunaTV 服务器直播源", "关闭后将不再获取 LunaTV 服务端提供的直播频道", live['lunaTvEnabled'] == true) +
          sw("live", "epgEnabled", "加载 EPG 节目单", "关闭后不拉取节目单与时移信息，直播连接更快", live['epgEnabled'] == true);
      h += section("直播源缓存") +
          radio("live", "cacheHours", "直播源缓存时间", CACHE_OPTIONS, (live['cacheHours']?.toString() ?? "24"));
      return h;
    }
    String catData() {
      final bangumiApi = data['bangumiProxyType']?.toString() ?? '';
      final bangumiImg = data['bangumiImageProxyType']?.toString() ?? '';
      var h = section("豆瓣数据源") +
          radio("data", "doubanSource", "豆瓣访问方式", DOUBAN_OPTIONS, (data['doubanSource']?.toString() ?? "")) +
          section("Bangumi 接口") +
          radio("data", "bangumiProxyType", "Bangumi API 反代", BANGUMI_API_OPTIONS, bangumiApi);
      if (bangumiApi == 'custom') {
        h += txt("data", "bangumiProxyUrl", "自定义 Bangumi 反代地址", "", (data['bangumiProxyUrl']?.toString() ?? ""), "");
      }
      h += section("Bangumi 图片") +
          radio("data", "bangumiImageProxyType", "Bangumi 图片代理", BANGUMI_IMG_OPTIONS, bangumiImg);
      if (bangumiImg == 'custom') {
        h += txt("data", "bangumiImageProxyUrl", "自定义图片代理地址", "", (data['bangumiImageProxyUrl']?.toString() ?? ""), "");
      }
      return h;
    }
    String catTheme() =>
        section("软件主题") +
        radio("theme", "mode", "主题模式", const <Map<String, String>>[
          const {'value': 'system', 'title': '跟随系统', 'subtitle': '随系统明暗自动切换'},
          const {'value': 'light', 'title': '明亮主题', 'subtitle': '背景为白色，文字为黑色'},
          const {'value': 'dark', 'title': '黑暗主题（默认）', 'subtitle': '背景为深色，适合暗光环境'},
        ], (theme['mode']?.toString() ?? ""));
    String catOther() {
      final logOn = other['logEnabled'] == true;
      var h = section("日志与调试") +
          sw("other", "logEnabled", "获取日志", "作为调试核查问题使用，正常情况请关闭以避免影响性能", logOn);
      if (logOn) {
        final logUrl = '$serverUrl/api/logs';
        h += "<div class='card'><div class='label'>下载日志</div><div class='hint'>开启后日志写入设备文件，点下方按钮可在手机下载</div><button class='primary' onclick=\"location.href='${esc(logUrl)}'\">下载日志文件</button></div>";
      }
      h += section("其他") +
          action("clear_cache", "清除缓存源", "清除海报、图片与豆瓣数据缓存，保留播放记录等数据");
      if (isWindows) {
        h += sw("other", "windowsFullscreenAlwaysOnTop", "全屏时窗口置顶", "全屏播放时窗口始终置顶", other['windowsFullscreenAlwaysOnTop'] == true);
      }
      return h;
    }

    final cats = const <List<String>>[
      const ['home', '首页'],
      const ['search', '搜索'],
      const ['account', '账号管理'],
      const ['server', '服务器管理'],
      const ['vod', '点播设置'],
      const ['live', '直播设置'],
      const ['live_sources', '直播源管理'],
      const ['data', '数据源设置'],
      const ['theme', '软件主题设置'],
      const ['other', '其他'],
    ];
    var navHtml = '';
    for (final c in cats) {
      navHtml += "<button class='nav' data-cat='${c[0]}' onclick=\"selectCat('${c[0]}')\">${c[1]}</button>";
    }

    final css = r'''* { box-sizing: border-box; -webkit-tap-highlight-color: transparent; }
    body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, "Helvetica Neue", Arial, sans-serif; margin: 0; background-color: #121212; color: white; min-height: 100vh; }
    #app { position: relative; min-height: 100vh; }
    #sidebar { position: absolute; left: 0; top: 0; bottom: 0; width: 160px; background-color: #1a1a1a; padding: 10px 6px; display: flex; flex-direction: column; gap: 4px; overflow-y: auto; z-index: 20; box-shadow: 2px 0 12px rgba(0,0,0,0.5); transform: translateX(0); transition: transform .2s ease; }
    #sidebar.collapsed { transform: translateX(-100%); }
    #menuBtn { position: fixed; top: 10px; left: 10px; width: 38px; height: 38px; border-radius: 50%; border: none; background-color: #1e1e1e; color: #fff; font-size: 20px; line-height: 38px; text-align: center; z-index: 30; cursor: pointer; box-shadow: 0 2px 8px rgba(0,0,0,0.4); padding: 0; }
    #menuBtn:active { background-color: #2a2a2a; }
    .brand { font-size: 14px; font-weight: 700; color: #00C8E0; padding: 4px 6px 10px; }
    .nav { border: none; text-align: left; background: transparent; color: #ccc; padding: 11px 8px; border-radius: 8px; font-size: 13px; cursor: pointer; }
    .nav.active { background-color: #00C8E0; color: #06222a; font-weight: 600; }
    #main { padding: 14px 14px 14px 52px; overflow-y: auto; -webkit-overflow-scrolling: touch; min-height: 100vh; box-sizing: border-box; }
    h2 { margin: 0 0 12px; font-size: 18px; color: #fff; }
    .section-title { font-size: 13px; color: #00C8E0; margin: 14px 2px 6px; font-weight: 600; }
    .card { background-color: #1e1e1e; border-radius: 10px; padding: 12px; margin-bottom: 10px; }
    .card-title { font-size: 13px; color: #00C8E0; margin-bottom: 4px; }
    .row { display: flex; align-items: center; justify-content: space-between; padding: 10px 0; border-bottom: 1px solid #2a2a2a; }
    .row:last-child { border-bottom: none; }
    .row-label { flex: 1; padding-right: 10px; }
    .label { font-size: 14px; color: #ddd; }
    .hint { font-size: 12px; color: #888; margin-top: 3px; }
    .link { display: block; color: #00C8E0; text-decoration: none; padding: 9px 0; font-size: 14px; border-bottom: 1px solid #2a2a2a; }
    .field { margin-bottom: 12px; }
    label { display: block; color: #aaa; font-size: 13px; margin-bottom: 5px; }
    input { width: 100%; padding: 11px; font-size: 14px; border-radius: 8px; border: 1px solid #333; background-color: #2a2a2a; color: white; box-sizing: border-box; }
    button.primary { width: 100%; padding: 12px; font-size: 15px; font-weight: 600; border: none; border-radius: 8px; background-color: #00C8E0; color: #06222a; cursor: pointer; margin-top: 4px; }
    button.primary:active { background-color: #0098B0; }
    .status { margin-top: 8px; font-size: 12px; color: #888; }
    .opt { display: flex; align-items: flex-start; justify-content: space-between; padding: 11px 6px; border-bottom: 1px solid #2a2a2a; cursor: pointer; }
    .opt:last-child { border-bottom: none; }
    .opt.sel { background-color: rgba(0,200,224,0.10); border-radius: 6px; }
    .opt-label { font-size: 14px; color: #fff; }
    .check { color: #00C8E0; font-size: 17px; margin-left: 10px; flex: 0 0 auto; }
    .info-val { font-size: 14px; color: #ddd; text-align: right; max-width: 60%; word-break: break-all; }
    .action-card { display: flex; align-items: center; justify-content: space-between; cursor: pointer; }
    .action-card .arrow { color: #888; font-size: 22px; }
    .switch { position: relative; width: 46px; height: 26px; flex: 0 0 auto; }
    .switch input { opacity: 0; width: 0; height: 0; }
    .slider { position: absolute; cursor: pointer; inset: 0; background: #444; border-radius: 26px; transition: .2s; }
    .slider:before { content: ""; position: absolute; height: 20px; width: 20px; left: 3px; bottom: 3px; background: white; border-radius: 50%; transition: .2s; }
    .switch input:checked + .slider { background: #00C8E0; }
    .switch input:checked + .slider:before { transform: translateX(20px); }
    .cat-page { display: none; }
    iframe.live-frame { width: 100%; height: calc(100vh - 40px); border: none; background: #121212; display: block; }''';

    final js = r'''var current = 'search';
    function selectCat(id) {
      current = id;
      var pages = document.querySelectorAll('.cat-page');
      for (var i = 0; i < pages.length; i++) { pages[i].style.display = 'none'; }
      var el = document.getElementById('cat-' + id);
      if (el) { el.style.display = 'block'; }
      var navs = document.querySelectorAll('.nav');
      for (var i = 0; i < navs.length; i++) { navs[i].classList.remove('active'); }
      var b = document.querySelector('.nav[data-cat="' + id + '"]');
      if (b) { b.classList.add('active'); }
      document.getElementById('sidebar').classList.add('collapsed');
      updateMenuIcon();
    }
    function updateMenuIcon() {
      var c = document.getElementById('sidebar').classList.contains('collapsed');
      document.getElementById('menuIcon').textContent = c ? '☰' : '✕';
    }
    function setStatus(m, c) {
      var el = document.getElementById('status');
      if (el) { el.textContent = m || ''; el.style.color = c || '#888'; }
    }
    function applySetting(g, k, v, el) {
      fetch('/api/settings', { method: 'POST', headers: {'Content-Type': 'application/json'}, body: JSON.stringify({group: g, key: k, value: v}) })
        .then(function(r){ return r.json(); })
        .then(function(d){
          if (d.status === 'ok') {
            setStatus('已保存', '#4CAF50');
            // 单选类选项：保存成功后即时高亮当前选中项，避免页面不刷新导致状态看不到。
            if (el && el.classList && el.classList.contains('opt')) {
              var card = el.closest('.card');
              if (card) {
                var opts = card.querySelectorAll('.opt');
                for (var i = 0; i < opts.length; i++) {
                  opts[i].classList.remove('sel');
                  var c = opts[i].querySelector('.check');
                  if (c) { c.textContent = ''; }
                }
                el.classList.add('sel');
                var chk = el.querySelector('.check');
                if (chk) { chk.textContent = '✓'; }
              }
            }
          } else {
            setStatus('失败: ' + (d.error || ''), '#FF6B6B');
          }
        })
        .catch(function(){ setStatus('保存失败，请检查网络', '#FF6B6B'); });
    }
    function runCommand(a) {
      setStatus('执行中…', '#888');
      fetch('/api/command', { method: 'POST', headers: {'Content-Type': 'application/json'}, body: JSON.stringify({action: a}) })
        .then(function(r){ return r.json(); })
        .then(function(d){ setStatus(d.status === 'ok' ? '已完成' : ('失败: ' + (d.error || '')), d.status === 'ok' ? '#4CAF50' : '#FF6B6B'); })
        .catch(function(){ setStatus('执行失败，请检查网络', '#FF6B6B'); });
    }
    function accountCommand(a) {
      setStatus('执行中…', '#888');
      fetch('/api/command/account', { method: 'POST', headers: {'Content-Type': 'application/json'}, body: JSON.stringify({action: a}) })
        .then(function(r){ return r.json(); })
        .then(function(d){ setStatus(d.status === 'ok' ? '已发送，电视响应中' : ('失败: ' + (d.error || '')), d.status === 'ok' ? '#4CAF50' : '#FF6B6B'); if (d.status === 'ok') { setTimeout(function(){ location.reload(); }, 600); } })
        .catch(function(){ setStatus('发送失败，请检查网络', '#FF6B6B'); });
    }
    function phoneSearch() {
      var kw = (document.getElementById('kw').value || '').trim();
      if (!kw) { setStatus('请输入搜索关键词', '#FF6B6B'); return; }
      fetch('/message', { method: 'POST', headers: {'Content-Type': 'application/json'}, body: JSON.stringify({message: kw}) })
        .then(function(){ setStatus('已发送，电视开始搜索：' + kw, '#4CAF50'); })
        .catch(function(){ setStatus('发送失败，请检查网络', '#FF6B6B'); });
    }
    function sendLogin() {
      fetch('/login', { method: 'POST', headers: {'Content-Type': 'application/json'}, body: JSON.stringify({ serverUrl: (document.getElementById('as').value || '').trim(), backupServerUrl: (document.getElementById('ab').value || '').trim(), username: (document.getElementById('au').value || '').trim(), password: (document.getElementById('ap').value || '').trim() }) })
        .then(function(r){ return r.json(); })
        .then(function(d){ setStatus(d.status === 'ok' ? '已发送，电视登录中' : ('失败: ' + (d.error || '')), d.status === 'ok' ? '#4CAF50' : '#FF6B6B'); })
        .catch(function(){ setStatus('失败，请检查网络', '#FF6B6B'); });
    }
    function sendSub() {
      fetch('/sub_account', { method: 'POST', headers: {'Content-Type': 'application/json'}, body: JSON.stringify({ username: (document.getElementById('su').value || '').trim(), password: (document.getElementById('sp').value || '').trim() }) })
        .then(function(r){ return r.json(); })
        .then(function(d){ setStatus(d.status === 'ok' ? '已保存' : ('失败: ' + (d.error || '')), d.status === 'ok' ? '#4CAF50' : '#FF6B6B'); if (d.status === 'ok') { setTimeout(function(){ location.reload(); }, 600); } })
        .catch(function(){ setStatus('失败，请检查网络', '#FF6B6B'); });
    }
    function toggleSubEdit() {
      var el = document.getElementById('subEdit');
      if (el) { el.style.display = el.style.display === 'none' ? 'block' : 'none'; }
    }
    document.getElementById('menuBtn').addEventListener('click', function() {
      document.getElementById('sidebar').classList.toggle('collapsed');
      updateMenuIcon();
    });
    var startCat = new URLSearchParams(location.search).get('cat');
    selectCat(startCat ? startCat : 'home');
    window.onerror = function(msg, url, line, col, err) {
      var p = document.getElementById('status');
      if (p) { p.textContent = '页面脚本错误: ' + msg + ' @行' + line; p.style.color = '#FF6B6B'; }
    };''';

    final html = '<!DOCTYPE html><html><head><title>海因影视 - 手机设置</title>'
        '<meta charset="UTF-8">'
        '<meta name="viewport" content="width=device-width, initial-scale=1.0, user-scalable=no">'
        '<style>${css}</style></head><body>'
        '<button id="menuBtn"><span id="menuIcon">☰</span></button>'
        '<div id="app"><div id="sidebar" class="collapsed"><div class="brand">海因影视</div>${navHtml}</div>'
        '<div id="main">'
        '<div class="cat-page" id="cat-home">${_h2("首页")}${catHome()}</div>'
        '<div class="cat-page" id="cat-search">${_h2("搜索")}${catSearch()}</div>'
        '<div class="cat-page" id="cat-account">${_h2("账号管理")}${catAccount()}</div>'
        '<div class="cat-page" id="cat-server">${_h2("服务器管理")}${catServer()}</div>'
        '<div class="cat-page" id="cat-vod">${_h2("点播设置")}${catVod()}</div>'
        '<div class="cat-page" id="cat-live">${_h2("直播设置")}${catLive()}</div>'
        '<div class="cat-page" id="cat-data">${_h2("数据源设置")}${catData()}</div>'
        '<div class="cat-page" id="cat-theme">${_h2("软件主题设置")}${catTheme()}</div>'
        '<div class="cat-page" id="cat-other">${_h2("其他")}${catOther()}</div>'
        '<div class="cat-page" id="cat-live_sources">${_h2("直播源管理")}<iframe class="live-frame" src="/?mode=live_sources"></iframe></div>'
        '<div class="status" id="status"></div>'
        '</div></div>'
        '<script>${js}</script>'
        '</body></html>';
    return html;
  }

  Map<String, dynamic> _err(String msg) => {'status': 'error', 'error': msg};

  bool _asBool(dynamic v) {
    if (v is bool) return v;
    if (v is String) return v.toLowerCase() == 'true';
    return false;
  }

  String _asString(dynamic v) => v == null ? '' : v.toString();

  int _asInt(dynamic v) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    if (v is String) return int.tryParse(v) ?? 0;
    return 0;
  }

  /// 读取当前设置快照，供统一手机设置页预填表单。
  Future<Map<String, dynamic>> _currentSettingsSnapshot() async {
    final vod = <String, dynamic>{
      'autoPlayNext': await UserDataService.getAutoPlayNextEpisode(),
      'autoSkip': await UserDataService.getAutoSkipOpeningEnding(),
      'autoSwitchSource': await UserDataService.getAutoSwitchSource(),
      'autoSwitchSourceTimeout': await UserDataService.getAutoSwitchSourceTimeout(),
      'autoSpeedTest': await UserDataService.getAutoSpeedTest(),
      'm3u8ProxyUrl': await UserDataService.getM3u8ProxyUrl(),
      'adFilter': await AdFilterService.isEnabled(),
      'hardwareDecoding': await UserDataService.getHardwareDecoding(),
      'playerBackend': (await UserDataService.getPlayerBackend()).name,
      'doubanSource': (await UserDataService.getDoubanDataSource()).name,
      'defaultQuality': await UserDataService.getDefaultQuality(),
      'bufferProfile': (await UserDataService.getBufferProfile()).name,
    };
    final live = <String, dynamic>{
      'lunaTvEnabled': await UserDataService.getLunaTvLiveEnabled(),
      'epgEnabled': await UserDataService.getEpgLoadEnabled(),
      'localProxy': await UserDataService.getLocalProxyEnabled(),
      'seamlessSwitch': await UserDataService.getSeamlessChannelSwitch(),
      'fcc': await UserDataService.getFccFastSwitch(),
      'livePlayerBackend': (await UserDataService.getLivePlayerBackend()).name,
      'cacheHours': await UserDataService.getLiveSourceCacheHours(),
    };
    final data = <String, dynamic>{
      'doubanSource': (await UserDataService.getDoubanDataSource()).name,
      'bangumiProxyType': (await UserDataService.getBangumiApiProxyType()).name,
      'bangumiProxyUrl': await UserDataService.getBangumiApiProxyUrl(),
      'bangumiImageProxyType':
          (await UserDataService.getBangumiImageProxyType()).name,
      'bangumiImageProxyUrl': await UserDataService.getBangumiImageProxyUrl(),
    };
    final theme = <String, dynamic>{
      'mode': ThemeModeService.instance.pref.name,
    };
    final other = <String, dynamic>{
      'logEnabled': await UserDataService.getLogEnabled(),
      'autoSpeedTest': await UserDataService.getAutoSpeedTest(),
    };
    final server = <String, dynamic>{
      'serverUrl': await UserDataService.getServerUrl(),
      'backupServerUrl': await UserDataService.getBackupServerUrl(),
      'autoSelectLowLatency': await UserDataService.getAutoSelectLowLatencyServer(),
      'preferIpv6':
          (await UserDataService.getInternetServerDnsPreference()) == InternetServerDnsPreference.ipv6,
    };
    final account = <String, dynamic>{
      'mainUsername': (await UserDataService.getMainAccount())?.username ?? '',
      'subUsername': (await UserDataService.getSubAccount())?.username ?? '',
      'subConfigured':
          ((await UserDataService.getSubAccount())?.password ?? '').isNotEmpty,
      'active': await UserDataService.getActiveAccount(),
    };
    return {
      'vod': vod,
      'live': live,
      'data': data,
      'theme': theme,
      'other': other,
      'server': server,
      'account': account,
    };
  }

  /// 应用一条手机下发的设置变更。返回 null 表示成功，否则返回错误映射。
  Future<Map<String, dynamic>?> _applySetting(
    String group,
    String key,
    dynamic value,
  ) async {
    try {
      switch (group) {
        case 'vod':
          switch (key) {
            case 'autoPlayNext':
              await UserDataService.saveAutoPlayNextEpisode(_asBool(value));
            case 'autoSkip':
              await UserDataService.saveAutoSkipOpeningEnding(_asBool(value));
            case 'autoSwitchSource':
              await UserDataService.saveAutoSwitchSource(_asBool(value));
            case 'hardwareDecoding':
              await UserDataService.saveHardwareDecoding(_asBool(value));
            case 'playerBackend':
              await UserDataService.savePlayerBackend(
                PlayerBackendType.values.byName(_asString(value)),
              );
            case 'doubanSource':
              await UserDataService.saveDoubanDataSource(
                DoubanDataSource.values.byName(_asString(value)),
              );
            case 'defaultQuality':
              await UserDataService.saveDefaultQuality(_asString(value));
            case 'autoSpeedTest':
              await UserDataService.saveAutoSpeedTest(_asBool(value));
            case 'adFilter':
              await AdFilterService.setEnabled(_asBool(value));
            case 'bufferProfile':
              await UserDataService.saveBufferProfile(
                BufferProfile.values.byName(_asString(value)),
              );
            case 'm3u8ProxyUrl':
              await UserDataService.saveM3u8ProxyUrl(_asString(value));
            case 'autoSwitchSourceTimeout':
              await UserDataService.saveAutoSwitchSourceTimeout(_asInt(value));
            default:
              return _err('未知的点播设置: $key');
          }
        case 'live':
          switch (key) {
            case 'lunaTvEnabled':
              await UserDataService.saveLunaTvLiveEnabled(_asBool(value));
            case 'epgEnabled':
              await UserDataService.saveEpgLoadEnabled(_asBool(value));
            case 'localProxy':
              await UserDataService.saveLocalProxyEnabled(_asBool(value));
            case 'seamlessSwitch':
              await UserDataService.saveSeamlessChannelSwitch(_asBool(value));
            case 'fcc':
              await UserDataService.saveFccFastSwitch(_asBool(value));
            case 'livePlayerBackend':
              await UserDataService.saveLivePlayerBackend(
                PlayerBackendType.values.byName(_asString(value)),
              );
            case 'cacheHours':
              await UserDataService.saveLiveSourceCacheHours(_asInt(value));
            default:
              return _err('未知的直播设置: $key');
          }
        case 'data':
          switch (key) {
            case 'doubanSource':
              await UserDataService.saveDoubanDataSource(
                DoubanDataSource.values.byName(_asString(value)),
              );
            case 'm3u8ProxyUrl':
              await UserDataService.saveM3u8ProxyUrl(_asString(value));
            case 'bangumiProxyType':
              await UserDataService.saveBangumiApiProxyType(
                BangumiApiProxyType.values.byName(_asString(value)),
              );
            case 'bangumiProxyUrl':
              await UserDataService.saveBangumiApiProxyUrl(_asString(value));
            default:
              return _err('未知的数据源设置: $key');
          }
        case 'theme':
          if (key == 'mode') {
            await ThemeModeService.instance
                .setPref(ThemeModePref.values.byName(_asString(value)));
          } else if (key == 'followSystem') {
            await ThemeModeService.instance.setPref(
              _asBool(value) ? ThemeModePref.system : ThemeModePref.dark,
            );
          } else {
            return _err('未知的主题设置: $key');
          }
          // 主题切换后请求 TV 重启（Android 走原生重建），使新主题彻底生效、
          // 避免仅原地刷新 shell 导致部分界面残留旧主题。与 App 内切换一致。
          ThemeModeService.requestRestart();
        case 'server':
          switch (key) {
            case 'autoSelectLowLatency':
              await UserDataService.setAutoSelectLowLatencyServer(
                _asBool(value),
              );
            case 'preferIpv6':
              await UserDataService.saveInternetServerDnsPreference(
                _asBool(value)
                    ? InternetServerDnsPreference.ipv6
                    : InternetServerDnsPreference.ipv4,
              );
            case 'internetUrl':
              await UserDataService.saveServerUrl(_asString(value));
            case 'backupUrl':
              await UserDataService.saveBackupServerUrl(_asString(value));
            default:
              return _err('未知的服务器设置: $key');
          }
        case 'other':
          switch (key) {
            case 'logEnabled':
              // 同步开关文件日志：AppLogger.setEnabled 内部已持久化 logEnabled，
              // 并开启/关闭写入线程；flush 保证切换前缓冲日志落盘。
              await AppLogger.setEnabled(_asBool(value));
              await AppLogger.flush();
            case 'autoSpeedTest':
              await UserDataService.saveAutoSpeedTest(_asBool(value));
            case 'windowsFullscreenAlwaysOnTop':
              await UserDataService.setWindowsFullscreenAlwaysOnTop(
                _asBool(value),
              );
            default:
              return _err('未知的其他设置: $key');
          }
        default:
          return _err('未知的设置分组: $group');
      }
      GlobalUiRefreshNotifier.instance.notify();
      return null;
    } catch (e) {
      return {'status': 'error', 'error': e.toString()};
    }
  }

  /// 处理手机下发的动作类命令（如清除缓存、立即测速并切换）。
  Future<Map<String, dynamic>?> _handleCommand(String action) async {
    try {
      switch (action) {
        case 'clear_cache':
          final cache = CacheService();
          await cache.init();
          await cache.clearPrefix('douban_');
          await HainTvCacheManager().emptyCache();
          return null;
        case 'server_speedtest':
          final primary = await UserDataService.getServerUrl();
          final backup = await UserDataService.getBackupServerUrl();
          await ServerLatencyService.selectBestServer(primary ?? '', backup);
          // 通知 TV 端服务器管理页刷新（若处于打开状态）。
          _serverActionController.add(const {'action': 'speedtest'});
          return null;
        default:
          return _err('未知命令: $action');
      }
    } catch (e) {
      return {'status': 'error', 'error': e.toString()};
    }
  }

  Future<String> startServer({
    String currentServerUrl = '',
    String currentBackupServerUrl = '',
  }) async {
    if (_server != null) return _serverUrl!;

    try {
      _server = await HttpServer.bind(InternetAddress.anyIPv4, controlPort);
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
            if (mode == 'settings' || mode.isEmpty) {
              // 未登录（TV 仍停在登录页）时，直接进登录页而不是展示空管理页。
              if (mode.isEmpty && !await UserDataService.isLoggedIn()) {
                _setCorsHeaders(request.response);
                request.response
                  ..statusCode = 302
                  ..headers.set('Location', '$_serverUrl?mode=login')
                  ..close();
                return;
              }
              final html = await _getSettingsPageHTML(_serverUrl!);
              _setCorsHeaders(request.response);
              request.response
                ..statusCode = 200
                ..headers.contentType = ContentType.html
                ..write(html)
                ..close();
              return;
            }
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
            final alreadyLoggedIn =
                loginMode ? await UserDataService.isLoggedIn() : false;
            final html = _getRemotePageHTML(
              _serverUrl!,
              loginMode: loginMode,
              serverConfigMode: serverConfigMode,
              subAccountMode: subAccountMode,
              alreadyLoggedIn: alreadyLoggedIn,
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
              // 缓冲关键词：若 TV 搜索页尚未打开，待其打开后再补触发搜索。
              _pendingSearchKeyword = message;
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
              final result = await _awaitHandlerResult(_loginHandler, {
                'serverUrl': serverUrl,
                'backupServerUrl': backupServerUrl,
                'username': username,
                'password': password,
              });
              _setCorsHeaders(request.response);
              request.response
                ..statusCode = result['status'] == 'ok' ? 200 : 400
                ..headers.contentType = ContentType.json
                ..write(jsonEncode(result))
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
              final result = await _awaitHandlerResult(_subAccountHandler, {
                'username': username,
                'password': password,
              });
              _setCorsHeaders(request.response);
              request.response
                ..statusCode = result['status'] == 'ok' ? 200 : 400
                ..headers.contentType = ContentType.json
                ..write(jsonEncode(result))
                ..close();
            } else {
              _setCorsHeaders(request.response);
              request.response
                ..statusCode = 400
                ..headers.contentType = ContentType.json
                ..write(jsonEncode({'status': 'error', 'error': '缺少用户名或密码'}))
                ..close();
            }
          } else if (request.method == 'GET' &&
              request.uri.path == '/api/info') {
            final playback = playbackStatusProvider != null
                ? await playbackStatusProvider!()
                : <String, dynamic>{};
            _setCorsHeaders(request.response);
            request.response
              ..statusCode = 200
              ..headers.contentType = ContentType.json
              ..write(jsonEncode({
                'status': 'ok',
                'deviceName': _deviceName,
                'port': controlPort,
                'playback': playback,
              }))
              ..close();
          } else if (request.method == 'GET' &&
              request.uri.path == '/api/playback_status') {
            final playback = playbackStatusProvider != null
                ? await playbackStatusProvider!()
                : <String, dynamic>{};
            _setCorsHeaders(request.response);
            request.response
              ..statusCode = 200
              ..headers.contentType = ContentType.json
              ..write(jsonEncode({'status': 'ok', 'playback': playback}))
              ..close();
          } else if (request.method == 'GET' &&
              request.uri.path == '/api/settings') {
            final snapshot = await _currentSettingsSnapshot();
            _setCorsHeaders(request.response);
            request.response
              ..statusCode = 200
              ..headers.contentType = ContentType.json
              ..write(jsonEncode({'status': 'ok', 'settings': snapshot}))
              ..close();
          } else if (request.method == 'GET' &&
              request.uri.path == '/api/settings/schema') {
            final schema = await SettingsSchema.build();
            _setCorsHeaders(request.response);
            request.response
              ..statusCode = 200
              ..headers.contentType = ContentType.json
              ..write(jsonEncode({'status': 'ok', 'schema': schema}))
              ..close();
          } else if (request.method == 'POST' &&
              request.uri.path == '/api/settings') {
            final body = await utf8.decoder.bind(request).join();
            final data = jsonDecode(body) as Map<String, dynamic>;
            final result = await _applySetting(
              (data['group'] as String?) ?? '',
              (data['key'] as String?) ?? '',
              data['value'],
            );
            _setCorsHeaders(request.response);
            request.response
              ..statusCode = result == null ? 200 : 400
              ..headers.contentType = ContentType.json
              ..write(jsonEncode(result ?? {'status': 'ok'}))
              ..close();
          } else if (request.method == 'POST' &&
              request.uri.path == '/api/command/search') {
            _searchCommandController.add(null);
            _setCorsHeaders(request.response);
            request.response
              ..statusCode = 200
              ..headers.contentType = ContentType.json
              ..write(jsonEncode({'status': 'ok'}))
              ..close();
          } else if (request.method == 'POST' &&
              request.uri.path == '/api/command') {
            final body = await utf8.decoder.bind(request).join();
            final data = jsonDecode(body) as Map<String, dynamic>;
            final result = await _handleCommand(
              (data['action'] as String?) ?? '',
            );
            _setCorsHeaders(request.response);
            request.response
              ..statusCode = result == null ? 200 : 400
              ..headers.contentType = ContentType.json
              ..write(jsonEncode(result ?? {'status': 'ok'}))
              ..close();
          } else if (request.method == 'POST' &&
              request.uri.path == '/api/command/account') {
            final body = await utf8.decoder.bind(request).join();
            final data = jsonDecode(body) as Map<String, dynamic>;
            final action = (data['action'] as String?) ?? '';
            if (action == 'switch_sub' ||
                action == 'switch_main' ||
                action == 'delete_sub' ||
                action == 'logout') {
              final result = await _awaitHandlerResult(
                  _accountActionHandler, {'action': action});
              _setCorsHeaders(request.response);
              request.response
                ..statusCode = result['status'] == 'ok' ? 200 : 400
                ..headers.contentType = ContentType.json
                ..write(jsonEncode(result))
                ..close();
            } else {
              _setCorsHeaders(request.response);
              request.response
                ..statusCode = 400
                ..headers.contentType = ContentType.json
                ..write(jsonEncode({'status': 'error', 'error': '未知的账号操作: $action'}))
                ..close();
            }
          } else if (request.method == 'POST' &&
              request.uri.path == '/api/command/server') {
            final body = await utf8.decoder.bind(request).join();
            final data = jsonDecode(body) as Map<String, dynamic>;
            final action = (data['action'] as String?) ?? '';
            if (action == 'speedtest') {
              final primary = await UserDataService.getServerUrl();
              final backup = await UserDataService.getBackupServerUrl();
              await ServerLatencyService.selectBestServer(primary ?? '', backup);
              _serverActionController.add(const {'action': 'speedtest'});
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
                ..write(jsonEncode({'status': 'error', 'error': '未知的服务器操作: $action'}))
                ..close();
            }
          } else if (request.method == 'GET' &&
              request.uri.path == '/api/logs') {
            // 手机「获取日志」开启后，提供日志文件下载（仿 TV 端 OtherSettingsPage 的日志下载服务）。
            await _handleLogDownload(request);
          } else if (request.uri.path.startsWith('/api/live_sources')) {
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

  /// 手机「获取日志」开启后的日志文件下载端点：/api/logs。
  /// 对齐 TV 端 OtherSettingsPage 的日志下载服务，手机可直接下载 hain_tv 日志文件。
  Future<void> _handleLogDownload(HttpRequest request) async {
    try {
      _setCorsHeaders(request.response);
      if (request.method == 'OPTIONS') {
        request.response
          ..statusCode = 204
          ..close();
        return;
      }
      await AppLogger.flush();
      final logPath = AppLogger.logFilePath;
      if (logPath.isEmpty || !File(logPath).existsSync()) {
        request.response
          ..statusCode = 404
          ..headers.contentType = ContentType.text
          ..write('日志文件不存在，请确认已开启「获取日志」并产生日志内容')
          ..close();
        return;
      }
      final file = File(logPath);
      final bytes = await file.readAsBytes();
      final fileName =
          'hain_tv_log_${DateTime.now().millisecondsSinceEpoch}.txt';
      request.response
        ..statusCode = 200
        ..headers.contentType = ContentType('text', 'plain', charset: 'utf-8')
        ..headers.add(
          'Content-Disposition',
          'attachment; filename="$fileName"',
        )
        ..add(bytes)
        ..close();
    } catch (e) {
      _setCorsHeaders(request.response);
      request.response
        ..statusCode = 500
        ..write('Internal Server Error')
        ..close();
    }
  }

  Future<void> _handleLiveSourcesRequest(HttpRequest request) async {
    try {
      if (request.method == 'GET' &&
          request.uri.path == '/api/live_sources') {
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

      // 分段排序：手机直播源页的 ▲/▼ 操作（内置源/本地源各自分组内移动）。
      if (request.method == 'POST' &&
          request.uri.path == '/api/live_sources/reorder') {
        final body = await utf8.decoder.bind(request).join();
        final data = jsonDecode(body) as Map<String, dynamic>;
        final id = (data['id'] as String?)?.trim() ?? '';
        final direction = (data['direction'] as String?)?.trim() ?? '';
        if (id.isEmpty || (direction != 'up' && direction != 'down')) {
          _setCorsHeaders(request.response);
          request.response
            ..statusCode = 400
            ..headers.contentType = ContentType.json
            ..write(jsonEncode({'status': 'error', 'error': '参数错误'}))
            ..close();
          return;
        }
        final combined = await LiveService.getAllSources();
        final index = combined.indexWhere((c) => c.id == id);
        if (index < 0) {
          _setCorsHeaders(request.response);
          request.response
            ..statusCode = 404
            ..headers.contentType = ContentType.json
            ..write(jsonEncode({'status': 'error', 'error': '直播源不存在'}))
            ..close();
          return;
        }
        await LiveSourceStorage.moveCombined(
            combined, index, direction == 'up' ? -1 : 1);
        LiveSourceRefreshNotifier.instance.notify();
        _liveSourcesChangedController.add(null);
        _setCorsHeaders(request.response);
        request.response
          ..statusCode = 200
          ..headers.contentType = ContentType.json
          ..write(jsonEncode({'status': 'ok'}))
          ..close();
        return;
      }

      // 清除单个直播源缓存（内置源清 LunaTV 缓存，本地源清频道缓存）。
      if (request.method == 'POST' &&
          request.uri.path == '/api/live_sources/clear_cache') {
        final body = await utf8.decoder.bind(request).join();
        final data = jsonDecode(body) as Map<String, dynamic>;
        final id = (data['id'] as String?)?.trim() ?? '';
        final config = (await LiveService.getAllSources())
            .cast<LiveSourceConfig?>()
            .firstWhere((c) => c!.id == id, orElse: () => null);
        if (config == null) {
          _setCorsHeaders(request.response);
          request.response
            ..statusCode = 404
            ..headers.contentType = ContentType.json
            ..write(jsonEncode({'status': 'error', 'error': '直播源不存在'}))
            ..close();
          return;
        }
        if (config.isBuiltin) {
          await LiveService.clearLunaTvCache(key: config.sourceKey);
        } else {
          final cacheKey = CacheService()
              .generateLiveChannelsCacheKey(sourceKey: config.id);
          await CacheService().delete(cacheKey);
        }
        LiveSourceRefreshNotifier.instance.notify();
        _setCorsHeaders(request.response);
        request.response
          ..statusCode = 200
          ..headers.contentType = ContentType.json
          ..write(jsonEncode({'status': 'ok'}))
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

        if (id.startsWith(LiveService.lunaTvBuiltinSourceId)) {
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
        LiveSourceRefreshNotifier.instance.notify();
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
        if (id.startsWith(LiveService.lunaTvBuiltinSourceId)) {
          _setCorsHeaders(request.response);
          request.response
            ..statusCode = 403
            ..headers.contentType = ContentType.json
            ..write(jsonEncode({'status': 'error', 'error': '系统内置源不允许删除'}))
            ..close();
          return;
        }
        await LiveSourceStorage.deleteConfig(id);
        LiveSourceRefreshNotifier.instance.notify();
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
    // 单例生命周期服务：手机后台管理服务为「常驻」设计——APP 启动即由 app_tv 启动，
    // 应一直存活到进程退出，不随某个页面（登录/搜索/直播/服务器管理）的 dispose 而关闭，
    // 否则离开该页面后 IP:端口 直接访问即失效。故 dispose 不调用 stopServer，
    // 端口由操作系统在进程退出时回收。StreamController 同理不在 dispose 中关闭，
    // 否则退出登录后重新进入登录页时控制器已关闭，导致二维码登录无法触发。
  }
}
