
<p align="center">
  <h1 align="center"> <code>video_player_ohos</code> </h1>
</p>




This project is developed based on [video_player@2.10.1](https://pub.dev/packages/video_player/versions/2.10.1).

## 1. Installation and Usage

### 1.1 Installation

Enter the project directory and add the following dependency in pubspec.yaml:

<!-- tabs:start -->

#### pubspec.yaml

```yaml
dependencies:
  video_player:
    git:
      url: https://gitcode.com/CPF-Flutter/flutter_packages.git
      path: packages/video_player/video_player
      # ref: video_player-v2.10.1-ohos-1.0.1
      ref: TAG  #   Please select the TAG according to the TAG version table below
```

Run the command

```bash
flutter pub get
```

<!-- tabs:end -->

**TAG Version Table**

| Flutter Version | TAG1 | TAG2 | Branch |
| :--- | :--- | :--- | :--- |
| 3.41 | `-` | `video_player-v2.11.1-ohos-1.0.0` | `br_video_player-v2.11.1_ohos` |
| 3.35 | `-` | `video_player-v2.10.1-ohos-1.0.1` | `br_video_player-v2.10.1_ohos` |
| 3.27 | `video_player-v2.10.0-ohos-1.0.0` | `video_player-v2.10.0-ohos-1.0.1` | `br_video_player-v2.10.0_ohos` |
| 3.22 | `video_player-v2.9.2-ohos-1.0.0` | `video_player-v2.9.2-ohos-1.0.1` | `br_video_player-v2.9.2_ohos` |
| 3.7 | `video_player-v2.7.2-ohos-1.0.0` | `video_player-v2.7.2-ohos-1.0.1` | `master` |

## 1.2 Usage Instructions

- This implementation uses `Texture` to render video frames by default.
- The `platformView` video rendering option is currently not exposed. The reason is not that OHOS native `XComponent + AVPlayer` capabilities are missing, but that the current `flutter_ohos` `PlatformView` still goes through the texture composition path, which does not fully match the video output pipeline of the media `XComponent`. In practice, issues such as "sound but no picture" occur, so it is not officially exposed as a capability.
- `DataSourceType.file` supports `fd://` file descriptor paths on OHOS.
- `formatHint` currently supports: `VideoFormat.hls`, `VideoFormat.dash`. The ArkTS native layer maps them to `MediaSource.setMimeType`.
- `VideoFormat.ss` is currently "best effort": the plugin does not actively intercept it, but if the system side does not have an available MIME mapping or protocol parsing capability, playback may fail and return a media-unsupported related error.
- `setPlaybackSpeed` supports the following speeds on OHOS: `0.125x`, `0.25x`, `0.5x`, `0.75x`, `1.0x`, `1.25x`, `1.5x`, `1.75x`, `2.0x`, `3.0x`.
  - **Difference from Android**: Android's `ExoPlayer` has a higher tolerance for playback rates, typically supporting a continuous range of `0.25x ~ 4.0x`; while OHOS's `AVPlayer` only supports discrete preset gears. If an incoming value is not in the OHOS supported list, the plugin will **map it to the nearest supported gear**.
  - **OHOS Playback Rate Mapping Table**:

    | Input Range | Actual Rate | Description |
    | :--- | :--- | :--- |
    | `< 0.125` | `0.125x` | Takes minimum value when below the lowest gear |
    | `0.125 ~ 0.25` | `0.25x` | Mapped to nearest `0.25x` |
    | `0.25 ~ 0.5` | `0.5x` | Mapped to nearest `0.5x` |
    | `0.5 ~ 0.75` | `0.75x` | Mapped to nearest `0.75x` |
    | `0.75 ~ 1.0` | `1.0x` | Normal rate |
    | `1.0 ~ 1.25` | `1.25x` | Mapped to nearest `1.25x` |
    | `1.25 ~ 1.5` | `1.5x` | Mapped to nearest `1.5x` |
    | `1.5 ~ 1.75` | `1.75x` | Mapped to nearest `1.75x` |
    | `1.75 ~ 2.0` | `2.0x` | Mapped to nearest `2.0x` |
    | `2.0 ~ 3.0` | `3.0x` | Takes `3.0x` when above `2.0x` |
    | `> 3.0` | `3.0x` | Takes maximum value when above the highest gear |

For usage examples, see [ohos/example](./example)


## 2. Constraints and Limitations

### 2.1 Compatibility

Tested and passed on the following versions

1. Flutter: 3.27.5-ohos-0.0.1; SDK: 5.0.0(12); IDE: DevEco Studio: 5.1.0.828; ROM: 5.1.0.130 SP8;

### 2.2 Permission Requirements

Among the following permissions, there is a `system_basic` permission, while the default application permission level is `normal`, which only allows `normal` level permissions. Therefore, you may encounter error **9568289** when installing the hap package. Please refer to the [documentation](https://developer.huawei.com/consumer/en/doc/harmonyos-guides-V5/bm-tool-V5#EN_TOPIC_0000001884757326__安装hap时提示code9568289-error-install-failed-due-to-grant-request-permissions-failed) to change the application level to `system_basic`.

#### Add permissions in module.json5 under the entry directory

Open `entry/src/main/module.json5` and add:

```yaml
"requestPermissions": [
  {
    "name": "ohos.permission.INTERNET",
    "reason": "$string:network_reason",
    "usedScene": {
      "abilities": [
        "EntryAbility"
      ],
      "when":"inuse"
    }
  },
]
```

#### Add the reason for requesting the above permissions under the entry directory

Open `entry/src/main/resources/base/element/string.json` and add:

```
{
  "string": [
    {
      "name": "network_reason",
      "value": "use network"
    },
  ]
}
```

## 3. API

> [!TIP] The "ohos Support" column marked yes indicates that the ohos platform supports this property; no means not supported. The usage is cross-platform consistent, with effects benchmarked against iOS or Android.

| Name                                          | return value                      | Description                                             | Type     | ohos Support |
| --------------------------------------------- | --------------------------------- | ------------------------------------------------------- | -------- | ------------ |
| init()                                        | Future<void>                      | Initializes the platform interface and releases all existing video player instances        | function | yes          |
| dispose(int textureId)                        | Future<void>                      | Releases the specified video resource                                      | function | yes          |
| create([DataSource](#DataSource) dataSource)  | Future<int?>                      | Creates a video player instance and returns its corresponding textureId         | function | yes          |
| setLooping(int textureId, bool looping)       | Future<void>                      | Sets whether to loop the video                                        | function | yes          |
| play(int textureId)                           | Future<void>                      | Starts video playback                                            | function | yes          |
| pause(int textureId)                          | Future<void>                      | Pauses video playback                                            | function | yes          |
| setVolume(int textureId, double volume)       | Future<void>                      | Sets the volume, range from 0.0 to 1.0                            | function | yes          |
| setPlaybackSpeed(int textureId, double speed) | Future<void>                      | Sets the playback speed. The OHOS platform currently supports the following speeds: 0.125×, 0.25×, 0.5×, 0.75×, 1.0×, 1.25×, 1.5×, 1.75×, 2.0×, 3.0×                                            | function | yes          |
| seekTo(int textureId, Duration position)      | Future<void>                      | Sets the video position to a [Duration] from the start. | function | yes          |
| getPosition(int textureId)                    | Future<[Duration](#Duration)>     | Gets the video position as [Duration] from the start.   | function | yes          |
| videoEventsFor(int textureId)                 | Stream<[VideoEvent](#VideoEvent)> | Returns an event stream of type [[VideoEventType](#VideoEventType)] | Stream   | yes          |
| setMixWithOthers(bool mixWithOthers)          | Future<void>                      | Sets the audio mode to allow mixing with other audio sources                  | function | yes          |

## 4. Properties

### DataSource

| Name        | Description                                            | Type                              | ohos Support |
| ----------- | ------------------------------------------------------ | --------------------------------- | ------------ |
| sourceType  | The original loading method of the video                                     | [DataSourceType](#DataSourceType) | yes          |
| uri         | The URI of the video file                                          | String?                           | yes          |
| formatHint  | Overrides the platform's default generic file format detection mechanism with the format set here | [VideoFormat](#VideoFormat)       | yes          |
| asset       | The name of the asset                                             | String?                           | yes          |
| package     | The package name that loads the asset                                       | String?                           | yes          |
| httpHeaders | HTTP request headers                                             | Map<String, String>               | yes          |

### DataSourceType

| Name                      | Description                            | Type | ohos Support |
| ------------------------- | -------------------------------------- | ---- | ------------ |
| DataSourceType.asset      | Application asset file                           | enum | yes          |
| DataSourceType.network    | Network resource                               | enum | yes          |
| DataSourceType.file       | Local file                               | enum | yes          |
| DataSourceType.contentUri | Video accessed via contentUri, only applicable to Android | enum |              |

### VideoFormat

| Name              | Description                   | Type | ohos Support |
| ----------------- | ----------------------------- | ---- | ------------ |
| VideoFormat.dash  | HTTP Dynamic Adaptive Streaming (MPEG-DASH) | enum | yes          |
| VideoFormat.hls   | HTTP Live Streaming (HLS)         | enum | yes          |
| VideoFormat.ss    | Smooth Streaming                    | enum | yes          |
| VideoFormat.other | Other formats                      | enum |              |

### VideoEvent

| Name               | Description                              | Type                              | ohos Support |
| ------------------ | ---------------------------------------- | --------------------------------- | ------------ |
| eventType          | The type of event                               | [VideoEventType](#VideoEventType) | yes          |
| duration           | The duration of the video                               | Duration?                         | yes          |
| size               | The size of the video                               | Size?                             | yes          |
| rotationCorrection | The angle the video needs to be rotated clockwise to ensure correct display | int?                              | yes          |
| buffered           | The buffered portion of the video                         | List<DurationRange>?              | yes          |
| isPlaying          | Whether the video is currently playing                     | bool?                             | yes          |

### VideoEventType

| Name                                | Description          | Type | ohos Support |
| ----------------------------------- | -------------------- | ---- | ------------ |
| VideoEventType.initialized          | Video initialization completed       | enum | yes          |
| VideoEventType.completed            | Playback finished             | enum | yes          |
| VideoEventType.bufferingUpdate      | Updates buffering status         | enum | yes          |
| VideoEventType.bufferingStart       | Video starts buffering         | enum | yes          |
| VideoEventType.bufferingEnd         | Video stops buffering         | enum | yes          |
| VideoEventType.isPlayingStateUpdate | Video playback state changes | enum | yes          |
| VideoEventType.unknown              | Unknown event received         | enum | yes          |

## 5. Known Issues

## 6. Open Source License

This project is based on [The MIT License (MIT)](https://gitcode.com/CPF-Flutter/flutter_packages/blob/master/packages/video_player/video_player_ohos/LICENSE). Please feel free to enjoy and participate in open source.



> Template version: v0.0.1
