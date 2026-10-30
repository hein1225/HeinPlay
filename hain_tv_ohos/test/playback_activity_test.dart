import 'package:flutter_test/flutter_test.dart';
import 'package:hain_tv/services/playback_activity.dart';
import 'package:hain_tv/services/search_service.dart';

/// 测速让路机制的单元测试。
///
/// 覆盖两件事：
///   1. [PlaybackActivity] 的播放状态 / 缓冲告急信号（含去抖与持续上限）
///   2. [SearchService.speedTestBudget] 的降档策略
void main() {
  group('PlaybackActivity 播放状态信号', () {
    late PlaybackActivity act;
    late DateTime clock;

    setUp(() {
      act = PlaybackActivity.instance;
      clock = DateTime(2026, 1, 1);
      act.now = () => clock;
    });

    tearDown(() {
      act.now = DateTime.now;
    });

    test('会话打开时不算取流中，上报取流后 isActive 为 true', () {
      final id = act.openSession();
      expect(act.isActive, isFalse);

      act.reportPlaying(id, true);
      expect(act.isActive, isTrue);

      act.closeSession(id);
      expect(act.isActive, isFalse);
    });

    test('暂停后 isActive 恢复 false（播放侧不再下载，无需让路）', () {
      final id = act.openSession();
      act.reportPlaying(id, true);
      expect(act.isActive, isTrue);

      act.reportPlaying(id, false);
      expect(act.isActive, isFalse);

      act.closeSession(id);
    });

    test('重复上报同一状态不会改变计数（幂等）', () {
      final id = act.openSession();
      act.reportPlaying(id, true);
      act.reportPlaying(id, true);
      act.reportPlaying(id, true);
      expect(act.isActive, isTrue);

      act.reportPlaying(id, false);
      expect(act.isActive, isFalse);
      act.closeSession(id);
    });
  });

  group('PlaybackActivity 当前播放源跟踪', () {
    late PlaybackActivity act;

    setUp(() {
      act = PlaybackActivity.instance;
    });

    test('未上报时 currentSourceKey 为 null', () {
      final id = act.openSession();
      expect(act.currentSourceKey, isNull);
      act.closeSession(id);
    });

    test('上报后 currentSourceKey 返回该源标识', () {
      final id = act.openSession();
      act.reportCurrentSource(id, 'ffzyapi.com+12345');
      expect(act.currentSourceKey, 'ffzyapi.com+12345');
      act.closeSession(id);
    });

    test('换源后 currentSourceKey 随之更新', () {
      final id = act.openSession();
      act.reportCurrentSource(id, 'ffzyapi.com+12345');
      expect(act.currentSourceKey, 'ffzyapi.com+12345');

      act.reportCurrentSource(id, '360zy.com+67890');
      expect(act.currentSourceKey, '360zy.com+67890');
      act.closeSession(id);
    });

    test('会话释放后 currentSourceKey 清除', () {
      final id = act.openSession();
      act.reportCurrentSource(id, 'ffzyapi.com+12345');
      expect(act.currentSourceKey, 'ffzyapi.com+12345');

      act.closeSession(id);
      expect(act.currentSourceKey, isNull);
    });

    test('传 null 视为没有有效源', () {
      final id = act.openSession();
      act.reportCurrentSource(id, 'ffzyapi.com+12345');
      act.reportCurrentSource(id, null);
      expect(act.currentSourceKey, isNull);
      act.closeSession(id);
    });

    test('未开启的会话上报无效（不污染状态）', () {
      act.reportCurrentSource(-1, 'ghost.com+1');
      expect(act.currentSourceKey, isNull);
    });
  });

  group('PlaybackActivity 缓冲告急信号', () {
    late PlaybackActivity act;
    late DateTime clock;

    setUp(() {
      act = PlaybackActivity.instance;
      clock = DateTime(2026, 1, 1);
      act.now = () => clock;
    });

    tearDown(() {
      act.now = DateTime.now;
    });

    test('告急需持续 3 秒才成立（去抖，避免起播瞬间误判）', () {
      final id = act.openSession();
      act.reportBufferStarved(id, true);
      expect(act.mustYield, isFalse, reason: '刚上报时不足 3 秒');

      clock = clock.add(const Duration(seconds: 2));
      expect(act.mustYield, isFalse, reason: '2 秒时仍未到确认时长');

      clock = clock.add(const Duration(seconds: 2));
      expect(act.mustYield, isTrue, reason: '超过 3 秒后告急成立');

      act.closeSession(id);
    });

    test('缓冲恢复后告急立即解除', () {
      final id = act.openSession();
      act.reportBufferStarved(id, true);
      clock = clock.add(const Duration(seconds: 5));
      expect(act.mustYield, isTrue);

      act.reportBufferStarved(id, false);
      expect(act.mustYield, isFalse);

      act.closeSession(id);
    });

    test('告急超过 45 秒自动解除（源本身不上报缓冲时不被永久阻断）', () {
      final id = act.openSession();
      act.reportBufferStarved(id, true);
      clock = clock.add(const Duration(seconds: 10));
      expect(act.mustYield, isTrue);

      clock = clock.add(const Duration(seconds: 40));
      expect(act.mustYield, isFalse, reason: '超过 45 秒持续上限，应自动解除');

      act.closeSession(id);
    });

    test('会话释放后告急信号一并清除', () {
      final id = act.openSession();
      act.reportBufferStarved(id, true);
      clock = clock.add(const Duration(seconds: 5));
      expect(act.mustYield, isTrue);

      act.closeSession(id);
      expect(act.mustYield, isFalse);
    });
  });

  group('SearchService.speedTestBudget 降档策略', () {
    test('无播放时维持满档（并发 2 / 采样 512KB / 分片并发 3）', () {
      final b = SearchService.speedTestBudget(playbackActive: false);
      expect(b.concurrency, 2);
      expect(b.sampleBytes, 512 * 1024);
      expect(b.segmentConcurrency, 3);
    });

    test('播放中降档（并发 2 / 采样 256KB / 分片并发 1）', () {
      final b = SearchService.speedTestBudget(playbackActive: true);
      // 🔴 2026-10-23（第二轮调整）：播放中批次并发由 1 提到 2。
      // 上一轮 Windows 实测「播放期间测速太慢」的主因是源与源之间完全串行
      // （20+ 源 × 最坏 8 秒 = 2~3 分钟），不是单源测速本身慢。
      expect(b.concurrency, 2);
      expect(b.sampleBytes, 256 * 1024);
      expect(b.segmentConcurrency, 1);
    });

    test('播放中峰值在途下载量从 3MB 降到 512KB（≥6 倍让路）', () {
      final idle = SearchService.speedTestBudget(playbackActive: false);
      final playing = SearchService.speedTestBudget(playbackActive: true);

      final idlePeak = idle.concurrency * idle.segmentConcurrency * idle.sampleBytes;
      final playingPeak =
          playing.concurrency * playing.segmentConcurrency * playing.sampleBytes;

      expect(idlePeak, 3 * 1024 * 1024);
      // 播放档 = 2 源 × 1 分片 × 256KB = 512KB
      expect(playingPeak, 512 * 1024);
      expect(idlePeak / playingPeak, greaterThanOrEqualTo(6));
    });
  });
}
