// 🔴 2026-10-07：ensureMpvModuleLoaded() 负责加载 libmpv_wrapper.so 并缓存模块。
//   加载顺序为「静态 import 优先，动态 import() 兜底」，两者都兼容 { default: ... } 包装。
//   （此前「静态 import 恒为 undefined」的判断已被证伪：真正的根因是自编译
//    libmpv.so 缺少 openssl 符号导致 dlopen 失败，见 MpvLib.ets 中的说明。）
export {
  MpvLib, EventObserver, LogObserver, MpvFormat, MpvEvent, ensureMpvModuleLoaded
} from './src/main/ets/MpvLib';

export { PlayerState } from './src/main/ets/models/PlayerState';

export { PlaylistMode } from './src/main/ets/models/PlaylistMode';

export {
  VideoTrack, AudioTrack, SubtitleTrack, Track, Tracks
} from './src/main/ets/models/Track';

export { Chapter } from './src/main/ets/models/Chapter';

export { Playlist } from './src/main/ets/models/Playlist';

export { Media, MediaOptions } from './src/main/ets/models/Media';

export { AudioParams } from './src/main/ets/models/AudioParams';

export { PlayerLog } from './src/main/ets/models/PlayerLog';

export { PlayerStream } from './src/main/ets/models/PlayerStream';

export { Stream, StreamListener } from './src/main/ets/utils/Stream';

export { MpvLogLevel, PlayerConfig } from './src/main/ets/models/PlayerConfig';

export { Player } from './src/main/ets/Player';

export { PlayerSurface } from './src/main/ets/PlayerSurface';
