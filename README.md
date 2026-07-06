# 海因影视 TV 版

基于 Flutter 开发的智能电视端影视播放应用，面向 Android TV 及大屏设备优化，同时支持 Web 与 Windows 桌面端。

## 功能特性

- **影视浏览**：首页推荐、电影、电视剧、综艺、动漫分类浏览。
- **详情与选集**：查看影片详情，选择剧集播放，切换播放源。
- **全屏播放**：支持播放/暂停、快进/快退、进度拖动、切换画面比例。
- **多播放器后端**：支持 ExoPlayer、MediaKit、video_player 三种后端，按需切换。
- **跳过片头片尾**：支持按电视剧维度设置跳过片段，自动跳过片头片尾并触发下一集。
- **搜索**：支持关键词搜索、最近搜索记录、搜索推荐。
- **个人中心**：播放历史、收藏、扫码登录、设置。
- **TV 遥控优化**：完整的焦点导航、方向键控制、返回键行为、控制栏自动隐藏。

## 支持平台

| 平台 | 状态 | 说明 |
|------|------|------|
| Android TV | 主要目标平台 | 支持 LEANBACK_LAUNCHER、遥控器焦点导航 |
| Web | 支持 | 受浏览器 CORS 限制，部分图片资源可能无法加载 |
| Windows | 支持 | 桌面调试与预览 |

## 项目结构

```
hain_tv/
├── android/              # Android 平台配置
│   ├── app/build.gradle.kts
│   ├── key.properties    # 发布签名配置（需妥善保管）
│   └── ...
├── lib/                  # Flutter 业务代码
│   ├── screens/          # 页面
│   ├── widgets/          # 自定义组件
│   ├── player/           # 播放器后端封装
│   ├── services/         # 网络与数据服务
│   ├── focus/            # TV 焦点管理
│   └── models/           # 数据模型
├── scripts/              # 构建脚本（PowerShell）
├── web/                  # Web 平台配置
├── windows/              # Windows 平台配置
└── pubspec.yaml
```

## 环境要求

- Flutter SDK: `^3.12.0`
- Dart SDK: 与 Flutter 版本匹配
- Android SDK: minSdk 21
- JDK: 用于 Android 构建

## 运行与调试

```bash
# 进入项目目录
cd hain_tv

# 获取依赖
flutter pub get

# 运行到 Android TV / 模拟器
flutter run

# 运行到 Web
flutter run -d chrome

# 运行到 Windows
flutter run -d windows
```

## 构建发布包

项目提供 PowerShell 构建脚本，位于 `scripts/` 目录：

```powershell
# 构建 Android TV Release APK
.\scripts\build_android_tv.ps1

# 构建 Web 版本
.\scripts\build_web.ps1

# 生成应用图标
.\scripts\generate_icons.ps1
```

Release 构建会使用 `android/key.properties` 中配置的签名密钥。

## 重要：需妥善保管的密钥文件

以下文件包含应用发布签名密钥信息，**切勿提交到 Git 仓库或泄露给第三方**。丢失密钥将导致无法更新已发布的应用。

### 1. `android/key.properties`

- **位置**：`hain_tv/android/key.properties`
- **用途**：配置 Release 签名所需的密钥库密码、别名及密钥库文件路径。
- **内容示例**：
  ```properties
  storePassword=******
  keyPassword=******
  keyAlias=hain_tv_key
  storeFile=hain_tv_keystore.jks
  ```
- **保管要求**：
  - 仅本地保存，不要上传到代码仓库。
  - 已加入 `.gitignore` 忽略规则，请确认不会被误提交。
  - 建议备份到安全的离线存储介质或密码管理器。

### 2. `android/app/hain_tv_keystore.jks`

- **位置**：`hain_tv/android/app/hain_tv_keystore.jks`
- **用途**：Android Release 签名密钥库文件，用于对 APK 进行数字签名。
- **别名**：`hain_tv_key`
- **保管要求**：
  - 这是最重要的密钥文件，丢失后无法为已有应用发布更新。
  - 不要提交到 Git，不要通过邮件、即时通讯工具发送。
  - 建议多重备份（加密 U 盘、私有云、密码管理器等）。

### 检查清单

- [ ] `android/key.properties` 已加入 `.gitignore`
- [ ] `android/app/hain_tv_keystore.jks` 已加入 `.gitignore`
- [ ] 密钥文件已备份到安全位置
- [ ] 未在代码、日志或文档中硬编码真实密码

## 注意事项

- Release 构建前请确认 `android/key.properties` 与 `hain_tv_keystore.jks` 路径正确且文件存在。
- 若在不同机器上构建，需要将 `hain_tv_keystore.jks` 文件复制到对应路径，并自行创建或更新 `android/key.properties`。
- Web 端受浏览器 CORS 策略限制，部分网络图片可能无法正常显示；Android / TV 端不受影响。

## 许可证

本项目为私有项目，未经授权不得分发或商用。
