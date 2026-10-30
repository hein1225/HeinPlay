// 🔴 2026-10-24 回归护栏：LivePlayer 退出暂停 + mpv 属性格式兜底的**源码契约**。
//
// 背景（真机日志实证）：
//   ① Android 退直播/换台时，日志先打「pause 失败: PlatformException(NO_VIEW)」
//      再打「pause 完成」——自相矛盾。根因是 `catchError().then()` 的写法：
//      catchError 的回调返回后 Future 仍以**成功**完成，后面的 then 照样执行。
//   ② `hwdec-current` 是 STRING 型属性（format=1），JNI 的「格式不符即丢弃」
//      兜底分支只把 DOUBLE/FLAG 当合法格式，于是每次硬解生效都误报一条
//      E 级「事件被丢弃」——而值其实已经取到并打印了。
//   ③ Flutter 卸载 PlatformView 的时机早于 Dart 的 dispose()，pause 必然打在
//      已销毁的 view 上。Android 侧已把 pause 的 NO_VIEW 降级为成功（语义上
//      「已停止」已达成：view.dispose() 里先执行了 core!!.destroy(handle)）。
//
// 本测试是**源码契约测试**：跨 Dart/Kotlin/C++ 三层的约束无法用纯 Dart 单测
// 覆盖，而这三处一旦被改回旧写法，症状只会出现在真机日志里、极难复现。
// 故在此固化断言，防回归。
//
// ⚠️ 定位方式说明：全文正则 `\.catchError\(...\)\s*\.then\(` 会跨越整个文件
//   匹配到无关的 `.then(`，产生假阳性。故此处一律用**位置断言**
//   （indexOf / lastIndexOf 比较下标），语义精确且不受排版影响。
//
// 用法：flutter test（工作目录即工程根，Directory.current 定位工程根）。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 工程根目录：flutter test 的工作目录就是工程根。
String _root() => Directory.current.path;

/// 读取工程内文件；不存在时返回 null（用于跨工程的差异化断言）。
String? _readIfExists(String relativePath) {
  final f = File('${_root()}/$relativePath');
  if (!f.existsSync()) return null;
  return f.readAsStringSync();
}

/// 剔除 Kotlin 行/块注释，保留字符串字面量内容。
///
/// 必要性：源码里大量注释会**原样引用被删掉的旧代码**（例如
/// `// 【原写法】core?.command(handle, arrayOf("vf", "remove"))`），
/// 直接对全文做子串匹配会命中注释里的示例，造成假失败。
/// 注释段替换为等长空格（保持后续下标不变），字符串字面量原样保留，
/// 避免把 URL 里的 `//` 误判成注释起点。
String _stripComments(String src) {
  // 用三引号 raw string：单引号 ' 出现在正则里（字符字面量分支），
  // 双引号 raw string 会被 " 截断，单引号 raw string 会被 ' 截断。
  final re = RegExp(
    r'''//.*$|/\*[\s\S]*?\*/|"(?:[^"\\\n]|\\.)*"|'(?:[^'\\\n]|\\.)*''',
    multiLine: true,
  );
  final out = StringBuffer();
  for (final m in re.allMatches(src)) {
    final t = m.group(0)!;
    if (t.startsWith('"') || t.startsWith("'")) {
      out.write(t);
    } else {
      out.write(' ' * t.length);
    }
  }
  return out.toString();
}

void main() {
  group('LivePlayer 退出暂停的日志语义', () {
    test('「pause 完成」必须位于 then 分支内，且 catchError 排在其后', () {
      final src = _readIfExists('lib/widgets/live/live_player.dart');
      expect(src, isNotNull, reason: 'live_player.dart 必须存在');

      // ⚠️ 用「英文单引号」定位，避免命中中文注释里的「pause 完成」。
      final completeIdx = src!.indexOf("'pause 完成'");
      expect(completeIdx, isNot(-1), reason: '未找到「pause 完成」日志');

      // then 分支必须包住「pause 完成」：.then((_) { ... 'pause 完成' ... })
      final thenIdx = src.lastIndexOf('.then((_)', completeIdx);
      expect(thenIdx, isNot(-1), reason: '「pause 完成」必须位于 .then 分支内');
      expect(thenIdx, lessThan(completeIdx));

      // catchError 必须排在「pause 完成」之后。若是旧写法 catchError().then()，
      // catchError 会在 then 之前 —— catchError 的回调返回后 Future 仍以成功
      // 完成，then 照样执行，于是暂停失败时也会打印「pause 完成」。
      final catchIdx = src.indexOf('.catchError(', completeIdx);
      expect(catchIdx, isNot(-1), reason: '未找到 catchError 分支');
      expect(
        catchIdx,
        greaterThan(completeIdx),
        reason: 'catchError 必须排在「pause 完成」之后：'
            'catchError().then() 的旧写法会让失败也打印「pause 完成」',
      );
    });

    test('退出暂停不得改动时序：pause 仍先于 500ms 延迟销毁', () {
      final src = _readIfExists('lib/widgets/live/live_player.dart');
      expect(src, isNotNull);

      final completeIdx = src!.indexOf("'pause 完成'");
      final delayIdx = src.indexOf('Duration(milliseconds: 500)');
      expect(completeIdx, isNot(-1));
      expect(delayIdx, isNot(-1));
      expect(
        completeIdx,
        lessThan(delayIdx),
        reason: 'pause 必须先于延迟销毁（桌面端时序依赖，不可颠倒）',
      );
    });
  });

  group('mpv 属性格式兜底（JNI）', () {
    test('兜底分支必须豁免 STRING 型属性（hwdec-current）', () {
      final src = _readIfExists(
        'android/app/src/main/cpp/heinplay_mpv_jni.cpp',
      );
      if (src == null) {
        // 该工程无 JNI 层（如鸿蒙），跳过。
        return;
      }

      // ⚠️ 各工程的 JNI 结构**不同**，断言必须覆盖差异化结构：
      //   - hain_tv：白名单分支 + 「格式不符即丢弃」兜底（`bool handled`），
      //     兜底原只认 DOUBLE/FLAG → STRING 型属性会被误报「事件被丢弃」，
      //     故必须按属性名豁免。
      //   - hain_tv_legacy：纯白名单分发，**没有**兜底分支，字符串型属性走
      //     独立的 push_event 通道，本就不存在该误报 → 无需豁免。
      final hasFallback = src.contains('bool handled');
      if (!hasFallback) {
        expect(
          src.contains('hwdec-current'),
          isTrue,
          reason: '无兜底分支的工程，hwdec-current 应走独立的字符串分支',
        );
        return;
      }

      expect(
        src.contains('isStringProp'),
        isTrue,
        reason: '需按属性名识别 STRING 型属性',
      );
      expect(
        src.contains('!isStringProp'),
        isTrue,
        reason: '兜底分支条件必须排除 STRING 型属性，否则误报「事件被丢弃」',
      );
    });
  });

  group('Android pause 的 NO_VIEW 降级（Kotlin）', () {
    test('pause 命中已销毁 view 时必须降级为成功而非报错', () {
      final src = _readIfExists(
        'android/app/src/main/kotlin/com/heinplay/hain_tv/MpvPlayerView.kt',
      );
      if (src == null) {
        // 该工程无 Android PlatformView 层（如鸿蒙），跳过。
        return;
      }
      expect(
        src.contains('call.method == "pause"'),
        isTrue,
        reason: 'pause 的 NO_VIEW 必须走降级分支（其余命令仍须报 NO_VIEW）',
      );
      expect(
        src.contains('NO_VIEW'),
        isTrue,
        reason: '其余命令仍须报 NO_VIEW，调用方据此走各自降级逻辑',
      );
    });
  });

  group('mpv loadfile 参数元数（legacy 特有）', () {
    test('loadfile 不得再传 "-1" 占位 index', () {
      final src = _readIfExists(
        'android/app/src/main/kotlin/com/heinplay/hain_tv/MpvPlayerView.kt',
      );
      if (src == null) return;

      // ⚠️ 2026-10-24 **修正归因**："-1" **并不是** err=-4 的原因。
      // "-1" 是 mpv 合法的「追加到播放列表末尾」语义（index 未给时 mpv 即按
      // 追加处理），真正的原因是 legacy 多了一行无参的 `vf remove`
      // （见下一组断言）。此处保留断言，是因为 loadfile 少占一个参数位更稳，
      // 且 start 经 property 下发语义更明确（file-local option）。
      //
      // 【历史误判，勿再重复】曾据「同批 hain_tv 手机版/TV 版 err=-4 均为 0」
      // 推断差异来自 legacy 多传的 "-1"。该推断不成立 —— 真正的差异是
      // legacy 有 `vf remove` 而主工程没有；且 err=-4 的时间戳**早于**同一次
      // open 的 `open url=` 日志 1ms，即它发生在 loadfile **之前**。
      expect(
        src.contains('cmd.add("-1")'),
        isFalse,
        reason: 'loadfile 只传 url + flags，不占用 index 参数位',
      );
      expect(
        src.contains('setPropertyString(handle, "start"'),
        isTrue,
        reason: 'start 改经 property 在 loadfile 之前下发'
            '（mpv 的 file-local option，官方即支持此用法）',
      );
    });
  });

  group('mpv vf 清理命令（err=-4 的真正来源）', () {
    test('legacy 不得下发无参的 `vf remove`', () {
      final src = _readIfExists(
        'android/app/src/main/kotlin/com/heinplay/hain_tv/MpvPlayerView.kt',
      );
      if (src == null) return;

      // mpv 0.37+ 的 vf 是 sub-command 风格：
      //     vf add <filter> / vf remove <filter> / vf toggle <filter>
      // `vf remove` **必须带 filter 名**；无参下发缺必填参数，mpv 返回
      // MPV_ERROR_INVALID_PARAMETER(-4)。本工程 libmpv.so 是 mpv 0.41
      // （flags 表含 insert-at / insert-at-play，仅 0.39+ 才有），正落该区间。
      //
      // 真机证据（XiaoPaiTech BA001.2026102409，legacy）：
      //   E HeinPlayMpvJni: command err=-4 (invalid parameter)   × 8
      // 与 8 次 open 严格一一对应，且时间戳早于同一次 open 的 `open url=` 1ms。
      // 对照组：主工程 hain_tv 无此行 ⇒ 同批日志 err=-4 = 0。
      expect(
        _stripComments(src).contains('arrayOf("vf", "remove")'),
        isFalse,
        reason: '无参 `vf remove` 被 mpv 0.37+ 判为缺少必填 filter 名 → err=-4',
      );
      expect(
        RegExp(r'command\([^)]*"vf"[^)]*"remove"').hasMatch(_stripComments(src)),
        isFalse,
        reason: '任何形式的 vf remove 命令都不得出现在 open 路径上',
      );
    });

    test('主工程 hain_tv 同样不得出现 vf remove（防回归引入）', () {
      final src = _readIfExists(
        '../hain_tv/android/app/src/main/kotlin/com/heinplay/hain_tv/MpvPlayerView.kt',
      );
      if (src == null) return;
      expect(
        _stripComments(src).contains('arrayOf("vf", "remove")'),
        isFalse,
        reason: '主工程是 err=-4 = 0 的对照组，不得引入同一处缺陷',
      );
    });
  });

  group('Android pause 的 DISPOSED 降级（Kotlin）', () {
    test('pause 命中已销毁 view（DISPOSED）时必须降级为成功', () {
      final src = _readIfExists(
        'android/app/src/main/kotlin/com/heinplay/hain_tv/MpvPlayerView.kt',
      );
      if (src == null) return;

      // legacy 的竞态落在 DISPOSED 一侧（view 仍在 views 表、但内部已 dispose），
      // 与 hain_tv 的 NO_VIEW 一侧不同 —— 只豁免 NO_VIEW 覆盖不到 legacy。
      // 真机日志里 legacy 每次换台都会刷 `MpvBackend pause error: mpv view disposed`。
      //
      // 判定方式：每个 result.error("DISPOSED" 分支的前 400 字符窗口内，
      // 必须已出现 pause 的降级判断（call.method == "pause"）。
      final re = RegExp(r'result\.error\("DISPOSED"');
      final matches = re.allMatches(src).toList();
      expect(
        matches,
        isNotEmpty,
        reason: '应至少存在一个 DISPOSED 报错分支',
      );
      for (final m in matches) {
        final from = m.start > 400 ? m.start - 400 : 0;
        final window = src.substring(from, m.start);
        expect(
          window.contains('call.method == "pause"'),
          isTrue,
          reason: '每个 DISPOSED 报错分支前都必须先判 pause 并降级为成功；'
              '「停止播放」语义此时已达成（core 已 destroy，handle/core 已归零）',
        );
      }
    });
  });
}
