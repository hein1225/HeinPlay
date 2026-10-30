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
}
