# @mpv-ohos/mpv-arkts

使用 ArkTS/C++ 编写的基于 mpv 的 HarmonyOS 音视频播放器。

## 功能特性

> [!IMPORTANT]
>
> 该模块仅支持 `arm64-v8a`

- [x] 基础音视频播放及控制
- [x] 硬件解码
- [x] Audio Vivid (菁彩三维声) 播放
- [x] 播放列表控制及循环模式选择
- [x] 音量和播放速度调节
- [x] 视频、音频和字幕轨道选择
- [x] 加载外部音轨和字幕
- [x] 同步读取状态和订阅事件流
- [x] 自定义 http headers

## 安装

通过 `ohpm` 命令进行安装

```shell
ohpm install @mpv-ohos/mpv-arkts
```

或在模块级 `oh-package.json5` 中将 `@mpv-ohos/mpv-arkts` 添加到 `dependencies`：

```json5
{
  "dependencies": {
    "@mpv-ohos/mpv-arkts": "1.0.0",
  }
}
```

### 网络媒体权限

如果应用需要播放网络媒体，请在模块级的 `module.json5` 中声明网络权限：

```json5
{
  "module": {
    "requestPermissions": [
      {
        "name": "ohos.permission.INTERNET"
      }
    ]
  }
}
```

## 快速上手

```typescript
import { Media, Player, PlayerSurface } from "@mpv-ohos/mpv-arkts";

@Entry
@ComponentV2
struct EntryView {
  private player: Player = new Player();

  aboutToAppear(): void {
    this.player.open(new Media("https://example.com/video.mp4"));
  }

  aboutToDisappear(): void {
    this.player.destroy();
  }

  build() {
    Row() {
      PlayerSurface({ player: this.player })
    }
    .height("100%")
    .width("100%")
  }
}
```

## 使用指南

### 目录

- [创建播放器](#创建播放器)
- [打开媒体或播放列表](#打开媒体或播放列表)
- [渲染视频](#渲染视频)
- [播放控制](#播放控制)
- [设置播放列表模式](#设置播放列表模式)
- [播放器状态](#播放器状态)
- [选择轨道](#选择轨道)
- [截图](#截图)
- [销毁播放器](#销毁播放器)

### 创建播放器

创建一个 `Player` 实例

```typescript
const player = new Player();
```

可以通过 `PlayerConfig` 自定义播放器初始化参数：

```typescript
const player = new Player(new PlayerConfig({
  deinterlace: true,
  logLevel: MpvLogLevel.Warn
}));
```

### 打开媒体或播放列表

#### `Media`

`Media` 可以接收文件 uri，或网络媒体链接：

```typescript
player.open(new Media("file://media/Photo/1310/VID_1/VID_1.mp4"));
```

通过设置第二个参数 `play`，可以控制加载媒体后是否立即开始播放：

```typescript
player.open(new Media("https://example.com/video.mp4"), false);
```

#### `Playlist`

播放器默认从 `0` 开始播放，可以通过第二个参数 `index` 进行控制。

```typescript
const playlist = new Playlist([
  new Media("https://example.com/1.mp4"),
  new Media("https://example.com/2.mp4"),
  new Media("https://example.com/3.mp4")
], 1);
player.open(playlist);
```

#### 媒体额外参数

可通过 `MediaOptions` 额外配置每个媒体的 http 请求头、播放开始时间和播放结束时间

```typescript
player.open(new Media(
  "https://example.com/1.mp4",
  {
    httpHeaders: new Map<string, string>([
      ["Referer", "https://example.com/"]
    ]),
    start: 0,
    end: 12 * 60 + 50
  }
));
```

### 渲染视频

将 `PlayerSurface` 放入组件树，并传入 `Player` 实例：

```typescript
PlayerSurface({ player: player })
  .width("100%")
  .height("100%")
```

### 播放控制

#### 播放/暂停

```typescript
player.play();
player.pause();
player.playOrPause();
```

#### 停止

停止当前播放的媒体或播放列表，但不会销毁播放器。

```typescript
player.stop();
```

#### 定位

使用绝对播放位置进行定位。

```typescript
player.seek(90);
```

#### 播放列表

```typescript
player.next();
player.previous();
player.jump(2);
```

#### 音量/倍速

```typescript
player.setVolume(80.0);
player.setSpeed(1.25);
```

### 设置播放列表模式

- `PlaylistMode.None`：播完暂停
- `PlaylistMode.File`：单集循环
- `PlaylistMode.Playlist`：播放列表循环
- `PlaylistMode.Random`：随机播放

```typescript
player.setPlaylistMode(PlaylistMode.File);
```

### 播放器状态

通过 `player.state` 立即读取当前状态：

```typescript
const track = player.state.track;
const chapters = player.state.chapters;
const duration = player.state.duration;
```

通过 `player.stream` 接受状态变更信息：

```typescript
playing: boolean = false;

player.stream.playing.listen((isPlaying: boolean) => {
  this.playing = isPlaying;
});
```

支持以下状态和事件流：

| 名称                    | 类型                | 说明              |
|-----------------------|-------------------|-----------------|
| `playlist`            | `Playlist`        | 当前播放列表          |
| `playing`             | `boolean`         | 播放状态            |
| `eof`                 | `boolean`         | 是否播放完成          |
| `duration`            | `number`          | 视频总时长（秒）        |
| `position`            | `number`          | 播放位置（秒）         |
| `volume`              | `number`          | 音量              |
| `speed`               | `number`          | 播放速度            |
| `buffering`           | `boolean`         | 是否因等待缓存而暂停播放    |
| `bufferingPercentage` | `number`          | 缓存百分比           |
| `buffer`              | `number`          | 缓冲位置（秒）         |
| `playlistMode`        | `PlaylistMode`    | 播放列表模式          |
| `track`               | `Track`           | 当前选中的视频、音频和字幕轨道 |
| `tracks`              | `Tracks`          | 可用的视频、音频和字幕轨道   |
| `chapters`            | `Chapter[]`       | 可用章节            |
| `videoParams`         | `VideoParams`     | 视频参数            |
| `videoBitrate`        | `number`          | 视频码率            |
| `audioParams`         | `AudioParams`     | 音频参数            |
| `audioBitrate`        | `number`          | 音频码率            |
| `log`                 | `Stream<PlayerLog>` | mpv 日志 (仅事件流)   |
| `error`               | `Stream<string>`  | mpv 错误日志 (仅事件流) |

### 选择轨道

可以通过 `player.state.tracks` 和 `player.stream.tracks` 获取可用轨道：

```typescript
const tracks = player.state.tracks;

if (tracks.video.length > 0) {
  player.setVideoTrack(tracks.video[0]);
}
if (tracks.audio.length > 0) {
  player.setAudioTrack(tracks.audio[0]);
}
if (tracks.subs.length > 0) {
  player.setSubtitleTrack(tracks.subs[0]);
}
```

#### 自动选择轨道

```typescript
player.setVideoTrack(VideoTrack.auto());
player.setAudioTrack(AudioTrack.auto());
player.setSubtitleTrack(SubtitleTrack.auto());
```

#### 禁用轨道

```typescript
player.setVideoTrack(VideoTrack.no());
player.setAudioTrack(AudioTrack.no());
player.setSubtitleTrack(SubtitleTrack.no());
```

#### 加载外部音频或字幕轨道

```typescript
player.setAudioTrack(AudioTrack.uri(
  "https://example.com/audio.m4a",
  "",
  "chi",
  "external"
));

player.setSubtitleTrack(SubtitleTrack.uri(
  "https://example.com/subtitles.vtt",
  "",
  "eng",
  "external"
));
```

### 截图

可以通过参数选择截图是否携带字幕，默认携带。返回 `PixelMap`。

```typescript
const pic = player.screenshot();
const picWithSub = player.screenshot(false);
```

### 销毁播放器

不再使用播放器时应使用 `destroy` 销毁播放器。播放器销毁后不能再次使用。

```typescript
player.destroy();
```

## 开发者指南

模块会在编译时会自动检测并下载 libmpv 二进制文件。该文件托管在 GitHub 上，注意网络连通性 (需要开启虚拟网卡 / TUN 模式)。

## 使用的三方库

- [mpv-player/mpv](https://github.com/mpv-player/mpv) 本项目基于 mpv 播放器
- [CPF-ApplicationTPC/aki](https://atomgit.com/CPF-ApplicationTPC/aki) 本项目使用 aki 简化 Node-API 的使用
- [simdjson/simdjson](https://github.com/simdjson/simdjson) 本项目使用 simdjson 优化 `mpv_node` 序列化性能

## 开源协议

MIT 许可证 (MIT License)
