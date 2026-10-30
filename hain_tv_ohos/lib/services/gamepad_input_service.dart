import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:ffi/ffi.dart';
import 'package:flutter/services.dart';
import 'package:hain_tv/utils/app_logger.dart';

/// 手柄语义按键（与具体平台无关的内部抽象）。
enum _PadButton { up, down, left, right, confirm, back }

/// 手柄语义按键对应的「标准按键」（逻辑键 + 物理键）。
class _KeyTarget {
  const _KeyTarget(this.logical, this.physical);

  final LogicalKeyboardKey logical;
  final PhysicalKeyboardKey physical;
}

/// 手柄（Gamepad）输入统一适配层。
///
/// ## 设计目标
/// 把手柄的 **A / B / 方向键** 变成 Flutter 已有的标准按键
/// （A=确认=回车，B=返回=ESC，方向键=方向键），从而**完整复用既有按键逻辑**：
/// 各页面的 `HardwareKeyboard` handler、焦点树里的 `Shortcuts` / `Actions` /
/// `FocusTraversal`、`Focusable` 的确认键判断等等，一行页面代码都不用改。
///
/// ## 三条输入来源（差异很大，必须分别处理）
/// * **Android**：手柄按键本身就会作为 Android KeyEvent 上报，且 Flutter 已把
///   keycode 96/97/98/99/100…（`KEYCODE_BUTTON_A/B/C/X/Y…`）映射为
///   [LogicalKeyboardKey.gameButtonA] / [gameButtonB] / …（见 Flutter 的
///   `kAndroidToLogicalKey`）。十字方向键上报为 `KEYCODE_DPAD_*` → 映射为
///   arrowUp/Down/Left/Right，**本来就可用**。因此 Android 只需在按键进入 Flutter
///   的第一站（[ui.PlatformDispatcher.onKeyData]）把 A/B **改写**成确认/返回键，
///   后面的整条链路看到的就是普通按键。
/// * **Windows**：XInput 手柄不产生任何窗口按键消息（没有 `WM_KEYDOWN`），Flutter
///   完全收不到，必须自己轮询系统自带的 `xinput*.dll`（纯 `dart:ffi`，不新增插件、
///   不需要重新编译 runner）。
/// * **Linux**：同理，手柄是独立输入设备，读 `/dev/input/js*` 的 8 字节事件流。
///
/// Windows / Linux 轮询到的按钮边沿会合成 [ui.KeyData] 从**同一个** onKeyData 出口
/// 注入，因此三条来源在 Flutter 侧的行为完全一致。
///
/// ## 按键约定
/// * A → 确认（回车 [LogicalKeyboardKey.enter]）
/// * B → 返回。Android 上「返回」的系统语义键是 [LogicalKeyboardKey.goBack]
///   （BACK 键），桌面端是 [LogicalKeyboardKey.escape]；两者都是各自平台上项目
///   既有的返回键，所以按平台分别映射。
/// * 方向键 → [LogicalKeyboardKey.arrowUp] / [arrowDown] / [arrowLeft] / [arrowRight]
///
/// 支持热插拔：未检测到手柄时低频探测（500ms），检测到后切换到 16ms 轮询。
class GamepadInputService {
  GamepadInputService._();

  static final GamepadInputService instance = GamepadInputService._();

  static const String _tag = 'Gamepad';

  /// Flutter 把 Android `KEYCODE_BUTTON_A(96)` / `B(97)` 映射成的逻辑键 id。
  static final int _gameButtonAId = LogicalKeyboardKey.gameButtonA.keyId;
  static final int _gameButtonBId = LogicalKeyboardKey.gameButtonB.keyId;

  bool _started = false;

  /// engine 原本的按键总入口（`ServicesBinding` 注册的 `KeyEventManager.handleKeyData`）。
  ui.KeyDataCallback? _downstream;

  final Stopwatch _clock = Stopwatch();

  late final Map<_PadButton, _KeyTarget> _targets = _buildTargets();

  _XInputPoller? _xinput;
  _LinuxJoystickPoller? _linuxPad;

  /// 日志去重：连续同一按键只打印一次。
  _PadButton? _lastLogged;

  /// 启用适配。
  ///
  /// 必须在 `WidgetsFlutterBinding.ensureInitialized()` 之后调用（否则
  /// [ui.PlatformDispatcher.onKeyData] 尚未由 framework 注册）。
  /// 仅 Android / Windows / Linux 生效，其余平台为空操作。
  void start() {
    if (_started) return;
    if (!(Platform.isAndroid || Platform.isWindows || Platform.isLinux)) return;

    final dispatcher = ui.PlatformDispatcher.instance;
    final downstream = dispatcher.onKeyData;
    if (downstream == null) {
      AppLogger.log(_tag, 'onKeyData 未就绪，手柄适配未启用');
      return;
    }

    _downstream = downstream;
    _clock.start();
    // 接管按键总入口：Android 在这里改写手柄 A/B 键；桌面轮询也从这个出口注入。
    dispatcher.onKeyData = _onKeyData;
    _started = true;

    if (Platform.isAndroid) {
      AppLogger.log(_tag, '手柄适配已启用（Android：手柄 A/B → 确认/返回，方向键沿用系统映射）');
    } else if (Platform.isWindows) {
      _xinput = _XInputPoller(_emit)..start();
    } else {
      _linuxPad = _LinuxJoystickPoller(_emit)..start();
    }
  }

  /// 停止适配并还原按键入口（App 级单例，正常生命周期内无需调用）。
  void stop() {
    _xinput?.stop();
    _xinput = null;
    _linuxPad?.stop();
    _linuxPad = null;
    final downstream = _downstream;
    if (_started && downstream != null) {
      ui.PlatformDispatcher.instance.onKeyData = downstream;
    }
    _started = false;
  }

  // ---------------------------------------------------------------- 按键分发

  /// 按键总入口：Android 上把手柄 A/B 改写为标准确认/返回键，其余原样透传。
  bool _onKeyData(ui.KeyData data) {
    final downstream = _downstream;
    if (downstream == null) return false;
    if (!Platform.isAndroid) return downstream(data);

    final pad = _androidPadFor(data.logical);
    if (pad == null) {
      _logUnmappedGamepadKey(data);
      return downstream(data);
    }

    final target = _targets[pad]!;
    if (data.type == ui.KeyEventType.down) {
      _recordPadLog(pad, target.logical, 'Android');
    }
    return downstream(
      ui.KeyData(
        timeStamp: data.timeStamp,
        type: data.type,
        physical: target.physical.usbHidUsage,
        logical: target.logical.keyId,
        character: null,
        synthesized: data.synthesized,
        deviceType: ui.KeyEventDeviceType.gamepad,
      ),
    );
  }

  _PadButton? _androidPadFor(int logicalId) {
    if (logicalId == _gameButtonAId) return _PadButton.confirm;
    if (logicalId == _gameButtonBId) return _PadButton.back;
    return null;
  }

  /// Flutter 的手柄按键（gameButton1..16 / gameButtonA..Z）的 keyId 落在该区间，
  /// 对应 Android keycode 96–110。
  static const int _gameButtonIdMin = 0x00200000301;
  static const int _gameButtonIdMax = 0x0020000031f;

  /// 已上报过的「未映射手柄按键」，避免刷屏。
  final Set<int> _reportedUnmappedKeys = <int>{};

  /// 诊断：手柄发来未映射的按键时记录一次。
  ///
  /// 用途是实测核对映射是否漏项（例如个别手柄的 A 键并不上报为 gameButtonA）。
  void _logUnmappedGamepadKey(ui.KeyData data) {
    final deviceType = data.deviceType;
    final isGamepadDevice = deviceType == ui.KeyEventDeviceType.gamepad ||
        deviceType == ui.KeyEventDeviceType.joystick;
    final inGameButtonRange =
        data.logical >= _gameButtonIdMin && data.logical <= _gameButtonIdMax;
    if (!isGamepadDevice && !inGameButtonRange) return;
    if (!_reportedUnmappedKeys.add(data.logical)) return;

    final label = LogicalKeyboardKey.findKeyByKeyId(data.logical)?.keyLabel ?? '未知';
    AppLogger.log(
      _tag,
      '手柄按键未映射: logical=0x${data.logical.toRadixString(16)} ($label) '
      'deviceType=${deviceType.name}',
    );
  }

  /// 按键映射日志（同一按键连续触发只记一次，避免刷屏）。
  void _recordPadLog(_PadButton pad, LogicalKeyboardKey target, String source) {
    if (_lastLogged == pad) return;
    _lastLogged = pad;
    AppLogger.log(_tag, '$source 手柄按键 → ${target.keyLabel}');
  }

  /// 合成一个标准按键事件注入 Flutter（桌面端轮询使用）。
  ///
  /// `synthesized: true` 让 framework 的 `KeyEventManager` 立即派发该事件
  /// （不必等待后续的原生 raw 消息），这是合成按键能即时生效的关键。
  void _emit(_PadButton pad, bool down, String source) {
    final downstream = _downstream;
    if (downstream == null) return;

    final target = _targets[pad]!;
    downstream(
      ui.KeyData(
        timeStamp: _clock.elapsed,
        type: down ? ui.KeyEventType.down : ui.KeyEventType.up,
        physical: target.physical.usbHidUsage,
        logical: target.logical.keyId,
        character: null,
        synthesized: true,
        deviceType: ui.KeyEventDeviceType.gamepad,
      ),
    );

    if (down) _recordPadLog(pad, target.logical, source);
  }

  Map<_PadButton, _KeyTarget> _buildTargets() {
    // 方向键：两端一致。
    final up = const _KeyTarget(LogicalKeyboardKey.arrowUp, PhysicalKeyboardKey.arrowUp);
    final down = const _KeyTarget(LogicalKeyboardKey.arrowDown, PhysicalKeyboardKey.arrowDown);
    final left = const _KeyTarget(LogicalKeyboardKey.arrowLeft, PhysicalKeyboardKey.arrowLeft);
    final right = const _KeyTarget(LogicalKeyboardKey.arrowRight, PhysicalKeyboardKey.arrowRight);

    // A 键 = 确认 = 回车。
    const confirm = _KeyTarget(LogicalKeyboardKey.enter, PhysicalKeyboardKey.enter);

    // B 键 = 返回：Android 用系统返回语义键（BACK），桌面用 ESC。
    final back = Platform.isAndroid
        ? const _KeyTarget(LogicalKeyboardKey.goBack, PhysicalKeyboardKey.escape)
        : const _KeyTarget(LogicalKeyboardKey.escape, PhysicalKeyboardKey.escape);

    return {
      _PadButton.up: up,
      _PadButton.down: down,
      _PadButton.left: left,
      _PadButton.right: right,
      _PadButton.confirm: confirm,
      _PadButton.back: back,
    };
  }
}

// ===========================================================================
// Windows：XInput 轮询
// ===========================================================================

/// `XINPUT_GAMEPAD`（12 字节）。
final class _XInputGamepad extends Struct {
  @Uint16()
  external int wButtons;

  @Uint8()
  external int bLeftTrigger;

  @Uint8()
  external int bRightTrigger;

  @Int16()
  external int sThumbLX;

  @Int16()
  external int sThumbLY;

  @Int16()
  external int sThumbRX;

  @Int16()
  external int sThumbRY;
}

/// `XINPUT_STATE`（16 字节）。
final class _XInputState extends Struct {
  @Uint32()
  external int dwPacketNumber;

  external _XInputGamepad gamepad;
}

typedef _XInputGetStateNative = Int32 Function(
  Uint32 dwUserIndex,
  Pointer<_XInputState> pState,
);
typedef _XInputGetStateDart = int Function(
  int dwUserIndex,
  Pointer<_XInputState> pState,
);

/// Windows 手柄轮询（XInput）。
///
/// 说明：只覆盖 XInput 设备（Xbox 系手柄，以及绝大多数第三方手柄的 XInput 模式）。
/// 纯 DInput 设备（部分老手柄 / PS 手柄的 DInput 模式）不会出现在这里——那类设备
/// 需要 DirectInput/HID 实现，目前未纳入；若手柄自带键盘映射模式，切过去即等效键盘。
class _XInputPoller {
  _XInputPoller(this._emit);

  final void Function(_PadButton pad, bool down, String source) _emit;

  // XINPUT_GAMEPAD.wButtons 位掩码。
  static const int _dpadUp = 0x0001;
  static const int _dpadDown = 0x0002;
  static const int _dpadLeft = 0x0004;
  static const int _dpadRight = 0x0008;
  static const int _buttonA = 0x1000;
  static const int _buttonB = 0x2000;

  static const String _source = 'Windows(XInput)';

  _XInputGetStateDart? _getState;
  Pointer<_XInputState>? _state;
  Timer? _timer;

  int _buttons = 0;
  final Set<_PadButton> _pressed = <_PadButton>{};
  bool _connected = false;

  void start() {
    final lib = _openLibrary();
    if (lib == null) {
      AppLogger.log('Gamepad', '未找到 xinput*.dll，Windows 手柄支持不可用');
      return;
    }
    try {
      _getState =
          lib.lookupFunction<_XInputGetStateNative, _XInputGetStateDart>('XInputGetState');
    } catch (e) {
      AppLogger.log('Gamepad', 'XInputGetState 解析失败: $e');
      return;
    }
    _state = calloc<_XInputState>();
    _schedule();
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
    final state = _state;
    if (state != null) {
      calloc.free(state);
      _state = null;
    }
  }

  static DynamicLibrary? _openLibrary() {
    // 依次尝试系统自带的三代 XInput；xinput1_4(Win8+) → xinput1_3(Win7) → xinput9_1_0。
    for (final name in const ['xinput1_4.dll', 'xinput1_3.dll', 'xinput9_1_0.dll']) {
      try {
        final lib = DynamicLibrary.open(name);
        AppLogger.log('Gamepad', '已加载 $name');
        return lib;
      } catch (_) {
        // 继续尝试下一个。
      }
    }
    return null;
  }

  void _schedule() {
    // 未接手柄时低频探测（省 CPU），接上后切到 16ms（≈60Hz）。
    final interval = _connected
        ? const Duration(milliseconds: 16)
        : const Duration(milliseconds: 500);
    _timer = Timer(interval, () {
      _poll();
      _schedule();
    });
  }

  void _poll() {
    final getState = _getState;
    final state = _state;
    if (getState == null || state == null) return;

    var found = false;
    for (var i = 0; i < 4 && !found; i++) {
      // 0 = ERROR_SUCCESS；非 0（1167 = ERROR_DEVICE_NOT_CONNECTED）表示空槽位。
      if (getState(i, state) != 0) continue;
      found = true;
      final buttons = state.ref.gamepad.wButtons;
      if (!_connected) {
        _connected = true;
        AppLogger.log('Gamepad', '检测到手柄（槽位 $i），已切换到 16ms 轮询');
      }
      if (buttons == _buttons) return;
      _buttons = buttons;
      _apply(buttons);
    }

    if (!found && _connected) {
      _connected = false;
      if (_buttons != 0) {
        _buttons = 0;
        _releaseAll();
      }
      AppLogger.log('Gamepad', '手柄已断开，回到低频探测');
    }
  }

  void _apply(int buttons) {
    _edge(_PadButton.up, (buttons & _dpadUp) != 0);
    _edge(_PadButton.down, (buttons & _dpadDown) != 0);
    _edge(_PadButton.left, (buttons & _dpadLeft) != 0);
    _edge(_PadButton.right, (buttons & _dpadRight) != 0);
    _edge(_PadButton.confirm, (buttons & _buttonA) != 0);
    _edge(_PadButton.back, (buttons & _buttonB) != 0);
  }

  void _edge(_PadButton pad, bool downNow) {
    if (downNow) {
      if (_pressed.add(pad)) _emit(pad, true, _source);
    } else if (_pressed.remove(pad)) {
      _emit(pad, false, _source);
    }
  }

  void _releaseAll() {
    for (final pad in _pressed.toList()) {
      _emit(pad, false, _source);
    }
    _pressed.clear();
  }
}

// ===========================================================================
// Linux：/dev/input/js* 事件流
// ===========================================================================

/// Linux 手柄读取（joystick API）。
///
/// 事件结构（内核 `struct js_event`，8 字节，小端）：
/// `u32 time | s16 value | u8 type | u8 number`
/// `type` 的位含义：`0x01`=按键，`0x02`=轴，`0x80`=设备初始化时补发的合成事件。
///
/// 按键编号沿用内核 joystick 约定：`0=A, 1=B, 2=X, 3=Y, 4=L1, 5=R1, 6=L2, 7=R2,
/// 8=SELECT, 9=START`。十字键通常以轴 6/7（X 系手柄）上报，故按 ±16000 阈值判方向。
///
/// ⚠️ 需要设备读权限（`/dev/input/js*` 一般 root:input 660，用户需在 `input` 组，
/// 或配置 udev 规则）；无权限时仅打印日志，不影响其它功能。
class _LinuxJoystickPoller {
  _LinuxJoystickPoller(this._emit);

  final void Function(_PadButton pad, bool down, String source) _emit;

  static const int _axisThreshold = 16000;

  final Set<_PadButton> _pressed = <_PadButton>{};
  bool _running = true;

  void start() {
    final found = <String>[];
    for (var i = 0; i < 4; i++) {
      final path = '/dev/input/js$i';
      if (!File(path).existsSync()) continue;
      found.add(path);
      unawaited(_readLoop(path));
    }
    if (found.isEmpty) {
      AppLogger.log('Gamepad', '未找到 /dev/input/js*，Linux 手柄支持不可用');
    } else {
      AppLogger.log('Gamepad', 'Linux 手柄设备: ${found.join(", ")}');
    }
  }

  void stop() {
    _running = false;
  }

  Future<void> _readLoop(String path) async {
    RandomAccessFile? raf;
    try {
      raf = await File(path).open();
      final buf = Uint8List(8);
      final bd = ByteData.sublistView(buf);
      while (_running) {
        final read = await raf.readInto(buf);
        if (read < 8) break;
        _onEvent(bd, path);
      }
    } catch (e) {
      AppLogger.log('Gamepad', '$path 读取失败: $e');
    } finally {
      try {
        await raf?.close();
      } catch (_) {
        // 忽略关闭异常。
      }
    }
  }

  void _onEvent(ByteData bd, String path) {
    final value = bd.getInt16(4, Endian.little);
    final type = bd.getUint8(6);
    final number = bd.getUint8(7);

    // 设备初始化时补发的合成事件，忽略。
    if ((type & 0x80) != 0) return;

    if ((type & 0x01) != 0) {
      switch (number) {
        case 0:
          _edge(_PadButton.confirm, value != 0, path);
        case 1:
          _edge(_PadButton.back, value != 0, path);
      }
      return;
    }

    if ((type & 0x02) != 0) {
      // 十字键（X 系手柄为轴 6=X / 7=Y，-32767 为左/上，+32767 为右/下）。
      switch (number) {
        case 6:
          _edge(_PadButton.left, value < -_axisThreshold, path);
          _edge(_PadButton.right, value > _axisThreshold, path);
        case 7:
          _edge(_PadButton.up, value < -_axisThreshold, path);
          _edge(_PadButton.down, value > _axisThreshold, path);
      }
    }
  }

  void _edge(_PadButton pad, bool downNow, String source) {
    if (downNow) {
      if (_pressed.add(pad)) _emit(pad, true, source);
    } else if (_pressed.remove(pad)) {
      _emit(pad, false, source);
    }
  }
}
