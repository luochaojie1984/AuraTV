# AuraTV（原生 Apple TV 局域网视频播放器）AI 执行交接文档

> **文档用途**：本文件是给后续执行 AI 的**完整、自包含、按严格顺序执行的施工手册**。请严格遵守“红线约束”与“阶段门禁”，**按编号顺序从 Step 0.1 逐条执行，上一步验收不通过，严禁跳到下一步**。

---

## 一、项目背景与执行红线（执行 AI 必读）

### 1.1 产品定位与功能范围

- **目标平台**：Apple TV 4K（原生 tvOS 17.0+，在 tvOS 26+ 自动启用 Liquid Glass）。
- **用户性质**：**个人自用**，有 Apple TV 真机 + **免费 Apple ID（无 \$99 付费开发者账号）**。
- **核心功能（必须实现）**：
  1. **原生精美暗色客厅 UI**：Liquid Glass / 毛玻璃质感、安全区规范、Siri Remote 顺滑焦点引擎、局域网文件浏览与「继续观看」首页。
  2. **主流局域网协议**：SMB2/SMB3（含局域网 Bonjour 自动发现）、WebDAV（HTTP/HTTPS + 301/302/307 直链重定向缓存 + Range 分片）、局域网测速工具。
  3. **全格式音视频与高画质**：MKV/MP4/TS/M2TS/MOV/BDMV；H.264/HEVC(10-bit)/AV1/VP9；VideoToolbox 硬解；联动 `AVDisplayManager` 触发原生 HDR10/HLG/Dolby Vision 与帧率匹配；TrueHD/DTS-HD MA 软解多声道 LPCM。
  4. **外挂字幕自动加载与深度样式自定义**：自动加载同目录与 `Subs/`、`Subtitles/` 下的外挂字幕（SRT/ASS/SSA/VTT/PGS），自动识别 UTF-8/GB18030/Big5 编码防乱码；播放页实时调整**垂直位置、字号大小、文字颜色、不透明度、描边、背景框、同步延迟、ASS 样式覆盖开关**。
  5. **仿安卓 MX Player 风格快进交互**：短按左右键 ±10s；**长按左右键时全屏主画面实时跟着变化**（基于关键帧索引缓存 + VideoToolbox I-Frame 单帧硬解 + 非线性加速曲线，松手立即恢复音画同步）。
- **明确不做（Out of Scope — 严禁擅自实现）**：
  - ❌ **不做海报墙、不做 TMDB / 豆瓣刮削、不做 `.nfo` 解析、不做演职员表/合集页面**。
  - ❌ **不做 iCloud / CloudKit 同步、不做 Top Shelf / Widget 扩展、不做 Push Notifications**。
  - ❌ **不安装任何 macOS 虚拟机**。

### 1.2 开发与运行环境事实

| 项目 | 真实配置 | 角色与注意事项 |
| :--- | :--- | :--- |
| **主力开发机** | Ubuntu 24.04.5 LTS (`192.168.5.157`, 用户 `lcj`) | AMD EPYC 48 线程 / 125GB 内存 / Docker 运行中。**源码必须放在 `/data/projects/AuraTV`**（`/data` 余 529G；不要把大文件塞在 `/`） |
| **局域网 SMB 测试环境** | `192.168.5.0/24` 同网段（已有 SMB 服务） | 仅作只读测试，**严禁删除、修改或写入用户任何现有媒体文件** |
| **tvOS 编译机** | GitHub Actions (`macos-latest` Apple Silicon) | 每次 `git push` 自动运行 `xcodegen` + `xcodebuild` 生成 `AuraTV-Unsigned.ipa` |
| **无线安装与自动续签** | `192.168.5.157` 上的 Docker (`bitxeno/atvloadly`) | 通过宿主机 `avahi-daemon` 发现 Apple TV，用免费 Apple ID 签名推送并每 7 天后台自动续签 |

### 1.3 给执行 AI 的 10 条铁律（Guardrails）

1. **严禁手改 `.xcodeproj`**：工程完全由根目录 `project.yml` 经 `XcodeGen` 自动生成；新增 Swift 文件只要放在规定目录即可自动纳入编译。
2. **严禁添加免费账号不支持的权限**：`project.yml` 和 `Info.plist` 中不得出现 `iCloud`、`CloudKit`、`App Groups`、`Push Notifications`、额外 App Extension Target。
3. **严禁在 `Packages/MediaCoreKit` 中引入 Apple 专属框架**：`MediaCoreKit` 必须能在 Ubuntu Linux 上 100% 通过 `swift test`，禁止在该包内 `import UIKit / SwiftUI / AVFoundation / Network / AMSMB2`。所有 Apple 平台适配代码统一放在 `Sources/TVAdapters/`、`Sources/PlaybackEngine/`、`Sources/TVApp/`。
4. **严禁使用 iOS 专属但 tvOS 不存在的 API**：禁止使用 `UISlider`、`UISwitch`、`UIDatePicker`、`navigationBarTitleDisplayMode(.inline)`、`statusBarHidden`、`UIDevice.current.orientation`、`UIApplication.shared.keyWindow`（用 `UIWindowScene` 替代）。
5. **严禁用 SwiftUI `.onMoveCommand` 实现“长按快进”**：`.onMoveCommand` 无法获取按下与松手事件，**必须**按 Step 2.3 的模板使用 UIKit `UIViewControllerRepresentable` 监听 `pressesBegan` / `pressesEnded` / `pressesCancelled`。
6. **Swift 6 严格并发规范**：跨并发边界结构体必须遵守 `Sendable`；所有 `@Published` / UI 控制器必须标注 `@MainActor`。
7. **安全红线**：严禁将任何密码（SSH 密码、SMB 密码、WebDAV 密码、Apple ID 密码）硬编码到源码、Git 提交或日志中。
8. **内存防 OOM 红线（Apple TV Jetsam）**：环形缓冲默认 `96 MB`（上限 `192 MB`），长按快进预览队列严格执行 **Latest-Wins（来新取消旧）**，严禁无界缓存视频帧。
9. **严格门禁执行**：每完成一个 Phase，必须先执行对应的验收命令并贴出真实输出；CI 报红必须修到全绿后再进入下一个 Phase。
10. **Linux 网络兼容性注意**：在 Ubuntu 的 Swift 代码里使用 `URLSession` 时，必须加上：
    ```swift
    #if canImport(FoundationNetworking)
    import FoundationNetworking
    #endif
    ```

---

## 二、总体目录结构蓝图（严格按此建目录）

```text
/data/projects/AuraTV/
├── project.yml                                 # XcodeGen 唯一工程描述文件
├── Makefile                                    # 常用快捷命令 (test / lint / check)
├── .gitignore
├── .github/
│   └── workflows/
│       └── tvos-ci.yml                         # Linux 单测 + macOS ARM64 产 AuraTV-Unsigned.ipa
├── Scripts/
│   ├── setup-ubuntu-ai.sh                      # 192.168.5.157 初始化脚本
│   └── deploy/
│       └── docker-compose.atvloadly.yml        # 192.168.5.157 无线安装与 7 天自动续签
├── Packages/
│   └── MediaCoreKit/                           # [Linux & tvOS 双平台可编译测试]
│       ├── Package.swift
│       ├── Sources/
│       │   ├── NetworkVFS/
│       │   │   ├── VFSModels.swift             # VFSFileItem / SourceConfig / MediaFileBadge
│       │   │   ├── VFSProvider.swift           # VFSProvider / VFSRandomAccessStream 协议
│       │   │   ├── ReadAheadStreamCache.swift  # 滑动窗口并发预读 + 秒取消缓存
│       │   │   └── WebDAVProvider.swift        # WebDAV PROPFIND + 302 直链缓存 + Range
│       │   ├── LocalStreamProxy/
│       │   │   └── LocalHTTPStreamProxy.swift  # 127.0.0.1 HTTP/1.1 Range 本地代理 + 头尾索引缓存
│       │   ├── SubtitleKit/
│       │   │   ├── SubtitleStyleConfig.swift   # 位置/字号/颜色/透明度/描边/背景/延迟/ASS覆盖
│       │   │   ├── SubtitleEncodingDetector.swift # UTF-8/UTF-16/GB18030/Big5 自动识别转码
│       │   │   ├── SubtitleMatcher.swift       # 同目录 + Subs/ 自动发现与语言优先级评分
│       │   │   └── SubtitleParser.swift        # SRT / VTT / ASS 时间轴与文本解析
│       │   └── AppPreferences/
│       │       ├── MediaSourceStore.swift      # SMB/WebDAV 源配置持久化 (JSON/SQLite)
│       │       ├── PlaybackHistoryStore.swift  # 继续观看与断点续播记录持久化
│       │       └── WebDAVBackupService.swift   # 可选免费 WebDAV 配置备份还原
│       └── Tests/
│           ├── NetworkVFSTests/
│           ├── LocalStreamProxyTests/
│           ├── SubtitleKitTests/
│           └── AppPreferencesTests/
└── Sources/                                    # [仅 tvOS / Apple 平台编译]
    ├── TVAdapters/
    │   ├── AMSMB2Provider.swift                # AMSMB2 适配 VFSProvider (SMB2/3)
    │   ├── BonjourDiscoveryService.swift       # Network.framework NWBrowser 发现 _smb._tcp
    │   └── KeychainCredentialStore.swift       # tvOS Keychain 安全存 SMB/WebDAV 密码
    ├── PlaybackEngine/
    │   ├── PlayerEngineProtocol.swift          # 统一播放引擎接口 & PlaybackStats
    │   ├── KSEngineAdapter.swift               # KSPlayer (VideoToolbox + Metal + HDR10/DV)
    │   ├── MPVEngineAdapter.swift              # MPVKit (libmpv + libass) 备核
    │   ├── DisplayModeCoordinator.swift        # AVDisplayManager 帧率 & HDR/DV 动态切换
    │   ├── MXScrubController.swift             # 仿 MX Player 非线性长按实时变画控制器
    │   ├── RemoteKeyCaptureView.swift          # UIKit pressesBegan/Ended 桥接 Siri Remote
    │   └── SubtitleOverlayView.swift           # 实时响应位置/大小/颜色/描边/背景的字幕渲染层
    └── TVApp/
        ├── App/
        │   └── AuraTVApp.swift                 # App 入口与全局依赖容器
        ├── DesignSystem/
        │   ├── AdaptiveGlassSurface.swift      # tvOS 26 Liquid Glass / tvOS 17 Material 封装
        │   ├── TVTheme.swift                   # 暗色影院色板、安全边距常量、字阶
        │   └── VideoBadgeParser.swift          # 从文件名提取 4K/DV/HDR10/HEVC/Atmos 徽章
        └── Features/
            ├── Home/
            │   └── HomeView.swift              # 首页：继续观看 + 我的网络源 + 局域网发现
            ├── Sources/
            │   ├── SourceEditorView.swift      # 添加/编辑 SMB / WebDAV 表单
            │   └── SpeedTestView.swift         # 局域网读取速度实时测速面板 (Mbps)
            ├── Browser/
            │   └── FileBrowserView.swift       # 精致暗色玻璃文件浏览器 (排序/搜索/进度条)
            ├── Player/
            │   ├── PlayerScreenView.swift      # 全屏播放页主容器
            │   ├── PlayerHUDView.swift         # 底部玻璃播控条 + MX 长按实时时间指示浮层
            │   ├── SubtitleSettingsDrawer.swift# 右侧半透明滑出字幕样式实时调节抽屉
            │   └── AudioAndEngineDrawer.swift  # 音轨切换 / 解码核切换 / 实时性能监控
            └── Settings/
                └── AppSettingsView.swift       # 快进模式与步长 / 缓存上限 / 默认字幕样式
```

---

## 三、分阶段详细施工步骤（严格按序号执行）

---

### Phase 0：打通环境、空壳编译与真机无线安装闭环（必须最先跑通！）

> **阶段目标**：不写任何复杂业务代码，先跑通「`192.168.5.157` 写代码 -> `swift test` 绿灯 -> GitHub Actions 生成 `AuraTV-Unsigned.ipa` -> `atvloadly` 装到 Apple TV 4K 真机亮屏」。管道通畅后再开始写核心功能。

#### Step 0.1：在 `192.168.5.157` 安装 Swift 6 与基础依赖
- **执行位置**：`192.168.5.157`（用户 `lcj`）
- **操作**：创建目录 `/data/projects/AuraTV/Scripts`，写入并执行 `setup-ubuntu-ai.sh`：
```bash
mkdir -p /data/projects/AuraTV/Scripts/deploy
cat <<'EOF' > /data/projects/AuraTV/Scripts/setup-ubuntu-ai.sh
#!/usr/bin/env bash
set -euo pipefail

sudo apt-get update
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
  clang ninja-build pkg-config zip unzip \
  binutils gnupg2 libc6-dev libedit2 libpython3-dev \
  libcurl4-openssl-dev libxml2-dev libsqlite3-dev \
  libssl-dev zlib1g-dev libz3-dev \
  avahi-daemon avahi-utils

sudo systemctl enable --now avahi-daemon

if ! command -v swiftly >/dev/null 2>&1 && [ ! -x "$HOME/.local/share/swiftly/bin/swiftly" ]; then
  curl -fL "https://download.swift.org/swiftly/linux/swiftly-$(uname -m).tar.gz" -o /tmp/swiftly.tar.gz
  mkdir -p /tmp/swiftly-extract
  tar zxf /tmp/swiftly.tar.gz -C /tmp/swiftly-extract
  /tmp/swiftly-extract/swiftly init --quiet-shell-followup -y
  rm -rf /tmp/swiftly.tar.gz /tmp/swiftly-extract
fi

source "${SWIFTLY_HOME_DIR:-$HOME/.local/share/swiftly}/env.sh"
swiftly link >/dev/null 2>&1 || true

source "${SWIFTLY_HOME_DIR:-$HOME/.local/share/swiftly}/env.sh"
swift --version
EOF
chmod +x /data/projects/AuraTV/Scripts/setup-ubuntu-ai.sh
bash /data/projects/AuraTV/Scripts/setup-ubuntu-ai.sh
```
- **验收标准**：
  - `swift --version` 输出 `Swift version 6.x`。
  - `systemctl is-active avahi-daemon` 输出 `active`。
  - `systemctl is-active docker` 输出 `active`。

#### Step 0.2：初始化 Git 仓库、`MediaCoreKit` 空壳与最小 tvOS App
- **执行位置**：`192.168.5.157:/data/projects/AuraTV`
- **操作**：
  1. 执行 `git init -b main`，创建 `.gitignore`（忽略 `.build/`, `*.xcodeproj`, `build/`, `*.ipa`, `.DS_Store`）。
  2. 创建 `Packages/MediaCoreKit/Package.swift`：
     ```swift
     // swift-tools-version: 6.0
     import PackageDescription

     let package = Package(
         name: "MediaCoreKit",
         platforms: [.tvOS(.v17)],
         products: [
             .library(name: "NetworkVFS", targets: ["NetworkVFS"]),
             .library(name: "LocalStreamProxy", targets: ["LocalStreamProxy"]),
             .library(name: "SubtitleKit", targets: ["SubtitleKit"]),
             .library(name: "AppPreferences", targets: ["AppPreferences"]),
         ],
         targets: [
             .target(name: "NetworkVFS"),
             .target(name: "LocalStreamProxy", dependencies: ["NetworkVFS"]),
             .target(name: "SubtitleKit"),
             .target(name: "AppPreferences", dependencies: ["NetworkVFS", "SubtitleKit"]),
             .testTarget(name: "NetworkVFSTests", dependencies: ["NetworkVFS"]),
             .testTarget(name: "LocalStreamProxyTests", dependencies: ["LocalStreamProxy"]),
             .testTarget(name: "SubtitleKitTests", dependencies: ["SubtitleKit"]),
             .testTarget(name: "AppPreferencesTests", dependencies: ["AppPreferences"]),
         ]
     )
     ```
  3. 在上述 4 个 Target 和 4 个 TestTarget 下各放一个最小占位文件（含 `XCTest` / `Testing` 绿灯用例）。
  4. 创建最小 `Sources/TVApp/App/AuraTVApp.swift`（显示「AuraTV Phase 0 Ready」文字即可）。
  5. 创建根目录 `project.yml`（**Phase 0 暂不引 KSPlayer，先确认纯空壳 2 分钟内能出包**；Phase 2 再加 KSPlayer/AMSMB2）：
     ```yaml
     name: AuraTV
     options:
       bundleIdPrefix: local.personal
       deploymentTarget:
         tvOS: "17.0"
     packages:
       MediaCoreKit:
         path: Packages/MediaCoreKit
     targets:
       AuraTV:
         type: application
         platform: tvOS
         sources:
           - path: Sources/TVApp
         dependencies:
           - package: MediaCoreKit
             product: NetworkVFS
           - package: MediaCoreKit
             product: LocalStreamProxy
           - package: MediaCoreKit
             product: SubtitleKit
           - package: MediaCoreKit
             product: AppPreferences
         settings:
           base:
             PRODUCT_BUNDLE_IDENTIFIER: local.personal.auratv
             SWIFT_VERSION: "6.0"
             TARGETED_DEVICE_FAMILY: "3"
             GENERATE_INFOPLIST_FILE: YES
             INFOPLIST_KEY_CFBundleDisplayName: AuraTV
             INFOPLIST_KEY_NSLocalNetworkUsageDescription: "用于发现和访问局域网内的 SMB / WebDAV 视频服务器"
             INFOPLIST_KEY_NSBonjourServices:
               - "_smb._tcp"
               - "_webdav._tcp"
               - "_webdavs._tcp"
     ```
  6. 创建 `.github/workflows/tvos-ci.yml`：
     ```yaml
     name: AuraTV CI (Ubuntu Tests + tvOS Unsigned IPA)

     on:
       push:
         branches: [ main, develop ]
       workflow_dispatch:

     jobs:
       core-tests-ubuntu:
         runs-on: ubuntu-latest
         steps:
           - uses: actions/checkout@v4
           - uses: swift-actions/setup-swift@v2
             with:
               swift-version: "6.0"
           - name: Test MediaCoreKit on Linux
             working-directory: Packages/MediaCoreKit
             run: swift test --parallel

       build-tvos-unsigned-ipa:
         needs: core-tests-ubuntu
         runs-on: macos-latest
         steps:
           - uses: actions/checkout@v4
           - name: Install XcodeGen
             run: brew install xcodegen
           - name: Generate Xcode Project
             run: xcodegen generate
           - name: Build tvOS Release App (Unsigned)
             run: |
               xcodebuild clean build \
                 -project AuraTV.xcodeproj \
                 -scheme AuraTV \
                 -sdk appletvos \
                 -destination 'generic/platform=tvOS' \
                 -configuration Release \
                 CODE_SIGNING_ALLOWED=NO \
                 CODE_SIGNING_REQUIRED=NO \
                 CODE_SIGN_IDENTITY="" \
                 SYMROOT="$(pwd)/build"
           - name: Package Unsigned IPA
             run: |
               mkdir -p Payload
               cp -R "build/Release-appletvos/AuraTV.app" Payload/
               zip -r "AuraTV-Unsigned.ipa" Payload
               rm -rf Payload
           - name: Upload Unsigned IPA
             uses: actions/upload-artifact@v4
             with:
               name: AuraTV-Unsigned-tvOS-IPA
               path: AuraTV-Unsigned.ipa
     ```
- **验收标准**：
  - 在 `192.168.5.157` 运行 `cd /data/projects/AuraTV/Packages/MediaCoreKit && swift test` 全部通过。
  - 推送到用户的 GitHub 仓库后，GitHub Actions 两个 Job 全绿，且能下载到 `AuraTV-Unsigned.ipa`。

#### Step 0.3：在 `192.168.5.157` 启动 `atvloadly` 并完成首次真机亮屏验证
- **执行位置**：`192.168.5.157` + Apple TV 4K 真机（由用户配合配对 PIN 码与登录免费 Apple ID）
- **操作**：写入 `Scripts/deploy/docker-compose.atvloadly.yml` 并启动：
```yaml
services:
  atvloadly:
    image: bitxeno/atvloadly:latest
    container_name: atvloadly
    restart: unless-stopped
    security_opt:
      - seccomp:unconfined
      - apparmor:unconfined
    ports:
      - "5533:80"
    volumes:
      - /data/atvloadly:/data
      - /var/run/dbus:/var/run/dbus
      - /var/run/avahi-daemon:/var/run/avahi-daemon
```
```bash
sudo mkdir -p /data/atvloadly && sudo chown -R lcj:lcj /data/atvloadly
cd /data/projects/AuraTV/Scripts/deploy
docker compose -f docker-compose.atvloadly.yml up -d
```
- **人工配合验收标准**：
  1. 浏览器访问 `http://192.168.5.157:5533`，发现局域网内的 Apple TV 4K 并完成配对；
  2. 登录专用免费 Apple ID，上传 Step 0.2 产出的 `AuraTV-Unsigned.ipa`；
  3. **Apple TV 4K 桌面出现 `AuraTV` 图标，打开后正常显示 `AuraTV Phase 0 Ready`**。
- **Phase 0 门禁**：未看到真机亮屏前，禁止进入 Phase 1。

---

### Phase 1：在 Ubuntu 完整开发并测试 `MediaCoreKit` 核心库

> **阶段目标**：在 `192.168.5.157` 本地写完并 100% 单元测试通过**网络协议抽象 + WebDAV + 本地流代理 + 滑动预读缓存 + 外挂字幕自动发现与编码转码 + 本地记录持久化**。这一阶段无需频繁跑 macOS CI，开发速度极快。

#### Step 1.1：实现 `NetworkVFS` 核心协议与滑动预读缓存
- **涉及文件**：
  - `Packages/MediaCoreKit/Sources/NetworkVFS/VFSModels.swift`
  - `Packages/MediaCoreKit/Sources/NetworkVFS/VFSProvider.swift`
  - `Packages/MediaCoreKit/Sources/NetworkVFS/ReadAheadStreamCache.swift`
- **具体要求**：
  1. `VFSFileItem` 包含：`id`, `name`, `path`, `isDirectory`, `size: Int64`, `modifiedAt: Date?`, `isVideo: Bool`（按 `.mkv/.mp4/.mov/.m4v/.ts/.m2ts/.avi/.flv/.webm/.wmv/.rmvb` 判断）, `isSubtitle: Bool`（按 `.srt/.ass/.ssa/.vtt/.sup/.sub/.idx` 判断）。
  2. `VFSRandomAccessStream` 协议定义：
     ```swift
     public protocol VFSRandomAccessStream: Sendable {
         var totalSize: Int64 { get }
         func read(offset: Int64, length: Int) async throws -> Data
         func close() async
     }
     ```
  3. `VFSProvider` 协议定义：`connect()`, `disconnect()`, `listDirectory(at:)`, `openStream(at:)`, `readFileData(at:maxBytes:)`（供加载外挂字幕小文件，默认上限 20MB）, `benchmarkThroughput(at:sampleBytes:) -> Double`（返回 Mbps）。
  4. `ReadAheadStreamCache`（`actor` 实现，线程安全）：
     - 将文件切分为固定块（默认 `chunkSize = 2 * 1024 * 1024`，即 2MB）；
     - 维护 LRU 块缓存，总上限可配置（默认 `96 MB`，绝不超过 `192 MB`）；
     - **关键帧索引区永久保护**：文件头 4MB 与文件尾 4MB 命中后优先常驻，防止 MKV `Cues` / MP4 `moov` 被淘汰（为 Phase 2 MX 长按实时快进打基础！）；
     - 顺序读取时后台预读后续 2 个块；发生大幅度随机 Seek（偏移跳变 > 8MB）时，**立刻调用 `Task.cancel()` 取消旧预读任务**。
- **验收标准**：在 `NetworkVFSTests` 用内存 Mock 大文件（模拟 50MB + 延迟）测试顺序读、随机跳转取消、头尾块常驻与内存上限不超标，`swift test` 通过。

#### Step 1.2：实现 `WebDAVProvider`（含 302 跳转缓存与 Range）
- **涉及文件**：
  - `Packages/MediaCoreKit/Sources/NetworkVFS/WebDAVProvider.swift`
- **具体要求**：
  1. 使用 `URLSession`（Linux 需 `#if canImport(FoundationNetworking)`）。
  2. 实现 `PROPFIND`（请求头 `Depth: 1`），使用 `XMLParser` 解析 WebDAV `multistatus -> response -> href / getcontentlength / resourcetype(collection) / getlastmodified`（兼容带命名空间前缀 `D:`、`d:`、`lp1:` 与无前缀节点，**这是低等级 AI 最容易漏掉的坑**，判断节点名时必须取 `elementName.split(separator: ":").last`）。
  3. 支持 `Basic` 认证与自定义 `User-Agent`。
  4. **301/302/307 直链缓存（国内 AList / OpenList / CD2 必备）**：
     - 打开视频流时先用自定义 `URLSessionTaskDelegate` 拦截重定向，将最终直链 URL + 过期时间（如默认缓存 5 分钟）保存在内存字典中；
     - 后续所有 `Range: bytes=start-end` 请求直接打向直链 URL；若直链返回 `401/403/404/410`，自动清空缓存并重新走原始 WebDAV 地址获取新直链重试 1 次。
- **验收标准**：在 `NetworkVFSTests` 中用 Swift 或 Python 起的本地临时 HTTP/WebDAV Mock 服务测试：目录列出（含中文 URL 编码解码）、302 跳转直链复用、Range 分片读取、`403` 过期重取，全部通过。

#### Step 1.3：实现 `LocalHTTPStreamProxy`（本地 `127.0.0.1` Range 代理）
- **涉及文件**：
  - `Packages/MediaCoreKit/Sources/LocalStreamProxy/LocalHTTPStreamProxy.swift`
- **具体要求**：
  1. 在 `127.0.0.1` 监听系统分配的随机空闲端口（`port = 0`），仅接收本机回环连接，避免暴露到局域网。
  2. 暴露 `register(stream:contentType:) -> URL` 方法，返回类似 `http://127.0.0.1:<port>/stream/<uuid>.mkv`。
  3. 完整支持：
     - `HEAD` 请求（返回 `200 OK`, `Content-Length`, `Accept-Ranges: bytes`）；
     - `GET` 不带 `Range`（返回 `200 OK`）；
     - `GET` 带 `Range: bytes=start-end` 或 `Range: bytes=start-`（返回 `206 Partial Content`, `Content-Range: bytes start-end/total`, `Content-Length`）；
     - 当客户端（如播放器长按快进取消旧连接）断开 socket 时，立即中止当前读取循环并释放资源，不泄漏句柄。
  4. 内部读取必须经过 Step 1.1 的 `ReadAheadStreamCache`。
- **验收标准**：在 `LocalStreamProxyTests` 中使用 `URLSession` 向代理发起 `HEAD`、多段并发 `Range` 请求与中途取消请求测试，校验字节 SHA256 与源文件 100% 一致。

#### Step 1.4：实现 `SubtitleKit`（外挂字幕自动发现 + 编码识别 + 样式模型 + 解析）
- **涉及文件**：
  - `Packages/MediaCoreKit/Sources/SubtitleKit/SubtitleStyleConfig.swift`
  - `Packages/MediaCoreKit/Sources/SubtitleKit/SubtitleEncodingDetector.swift`
  - `Packages/MediaCoreKit/Sources/SubtitleKit/SubtitleMatcher.swift`
  - `Packages/MediaCoreKit/Sources/SubtitleKit/SubtitleParser.swift`
- **具体要求**：
  1. **`SubtitleStyleConfig`**（`Codable, Equatable, Sendable`）：必须包含以下全部字段：
     - `fontSize: Double`（默认 `56`，范围 `32...96`）
     - `bottomOffsetRatio: Double`（默认 `0.06`，范围 `0.0...0.35`，控制垂直位置）
     - `textColorHex: String`（默认 `"#FFF5DC"` 护眼暖白，附带预设：纯白 `#FFFFFF`、电影黄 `#FFD700`、暖白 `#FFF5DC`、冰蓝 `#7CE8FF`、浅绿 `#A8FF9E`）
     - `textOpacity: Double`（默认 `0.92`，范围 `0.4...1.0`）
     - `fontWeight: SubtitleFontWeight`（`regular / medium / semibold / bold`）
     - `outlineWidth: Double`（默认 `2.5`，范围 `0...6`）
     - `outlineColorHex: String`（默认 `"#000000"`）
     - `backgroundOpacity: Double`（默认 `0.0`，范围 `0.0...0.8`）
     - `delaySeconds: Double`（默认 `0.0`，范围 `-30.0...30.0`）
     - `overrideASSStyles: Bool`（默认 `false`；开启后强行将 ASS 样式替换为以上自定义配置）
  2. **`SubtitleMatcher`**（自动发现算法）：
     - 输入：视频文件名 `videoFileName`、同目录文件列表、可选 `Subs/` 和 `Subtitles/` 文件列表；
     - 匹配评分规则：
       - `+100`：字幕去掉扩展名（及语言后缀如 `.chs/.zh/.sc/.eng`）与视频去掉扩展名完全一致（不区分大小写）；
       - `+60`：字幕文件名以视频核心名前缀开头，或匹配到同一集号 `SxxExx`；
       - 语言加分：`chs/sc/zh-hans/简体/简中` `+30`，`双语/chs&eng/chs.eng` `+25`，`cht/tc/zh-hant/繁体/繁中` `+20`，`eng/en` `+10`；
       - 格式微调：`.ass/.ssa` `+5`（默认优于纯 `.srt`）；
     - 输出：按总分降序排列的 `[MatchedSubtitleCandidate]`，供播放器默认自动挂载第 1 项，其余全部列在播放页字幕菜单中。
  3. **`SubtitleEncodingDetector`**：
     - 按顺序检测：UTF-8 BOM -> UTF-16 LE/BE BOM -> 严格 UTF-8 校验 -> GB18030/GBK -> Big5 -> Windows-1252；统一输出规范 UTF-8 `String`。
  4. **`SubtitleParser`**：
     - 实现 `.srt`、`.vtt` 解析为 `[SubtitleCue(startTime, endTime, text)]`；
     - 实现 `.ass/.ssa` 的 `[Events]` `Dialogue:` 提取（清洗 `{...}` 特效标签用于纯文本/覆盖样式渲染模式，保留原始 ASS 文本供 `libass` 原生特效渲染模式）；
     - 提供 `activeCues(at playbackTime: TimeInterval, delay: TimeInterval) -> [SubtitleCue]`（二分查找，O(log N)）。
- **验收标准**：`SubtitleKitTests` 覆盖 ≥ 15 组用例（同名多语言字幕自动排序、`Subs/` 子目录命中、GBK 中文字幕无乱码转换、SRT/ASS 时间轴查找与延迟偏移），`swift test` 全部通过。

#### Step 1.5：实现 `AppPreferences`（轻量本地持久化，无海报表）
- **涉及文件**：
  - `Packages/MediaCoreKit/Sources/AppPreferences/MediaSourceStore.swift`（增删改查 SMB / WebDAV 源元数据；**密码不存明文 JSON**，仅存 `credentialKey` 引用，tvOS 端用 Keychain 存取）
  - `Packages/MediaCoreKit/Sources/AppPreferences/PlaybackHistoryStore.swift`（按 `sourceID + filePath` 记录 `lastPositionSeconds`, `durationSeconds`, `lastPlayedAt`, `selectedSubtitlePath`, `selectedAudioTrackID`；自动判定“已看完”（进度 > 95%））
  - `Packages/MediaCoreKit/Sources/AppPreferences/WebDAVBackupService.swift`（将源列表（不含密码）、观看进度、字幕样式导出为单个 JSON 上传至用户指定的 WebDAV 路径，支持一键恢复）
- **Phase 1 门禁**：
  - `cd /data/projects/AuraTV/Packages/MediaCoreKit && swift test --parallel` 全部测试绿灯（0 warning / 0 error）。
  - `git push` 触发 GitHub Actions，确保 Ubuntu 测试和 tvOS CI 仍然全绿。

---

### Phase 2：tvOS 协议适配、双核播放引擎、MX 实时快进与字幕渲染层

> **阶段目标**：接入 `AMSMB2` + `KSPlayer`（先打通主核，再挂载 `MPVKit` 备核），实现 **MX Player 长按实时变画快进** 和 **自定义外挂字幕渲染层**。

#### Step 2.1：更新 `project.yml` 接入 `AMSMB2` 与 `KSPlayer`
- **修改文件**：`/data/projects/AuraTV/project.yml`
- **操作**：
  1. 在 `packages:` 中增加：
     ```yaml
     AMSMB2:
       url: https://github.com/amosavian/AMSMB2.git
       from: "4.0.3"
     KSPlayer:
       url: https://github.com/kingslay/KSPlayer.git
       branch: main
     ```
  2. 在 `AuraTV` target 的 `sources:` 中增加 `Sources/TVAdapters` 和 `Sources/PlaybackEngine`，在 `dependencies:` 中增加 `AMSMB2` 与 `KSPlayer`（**注意**：如 GitHub Actions 解析 `KSPlayer` 依赖时拉取 `FFmpegKit` XCFramework，确保仅链接 tvOS 切片且关闭 `CODE_SIGNING_ALLOWED`）。
  3. 先不急着加 `MPVKit`——**先确保 `AMSMB2 + KSPlayer` 在 GitHub Actions `macos-latest` 上一次编译通过并能产出 `.ipa`**！

#### Step 2.2：实现 `TVAdapters`（SMB2/3 + Bonjour 局域网发现 + Keychain）
- **涉及文件**：
  - `Sources/TVAdapters/AMSMB2Provider.swift`：封装 `AMSMB2`，实现 `MediaCoreKit.VFSProvider` 与 `VFSRandomAccessStream`（内部支持按 Offset `pread` 并发安全读取与断线自动重连）。
  - `Sources/TVAdapters/BonjourDiscoveryService.swift`：使用 Apple 原生 `Network.framework` 的 `NWBrowser` 同时浏览 `_smb._tcp` 和 `_webdav._tcp`，实时发布局域网内发现的服务器主机名与 IP/端口。
  - `Sources/TVAdapters/KeychainCredentialStore.swift`：使用 `Security.framework` (`SecItemAdd` / `SecItemCopyMatching`) 存储 SMB / WebDAV 账号密码。

#### Step 2.3：实现 Siri Remote 长按捕获桥接与 `MXScrubController`（最关键防踩坑模块！）
- **涉及文件**：
  - `Sources/PlaybackEngine/RemoteKeyCaptureView.swift`
  - `Sources/PlaybackEngine/MXScrubController.swift`
- **低等级 AI 必读实现规范（请直接基于此骨架完善，切勿改回 `.onMoveCommand`）**：
```swift
import SwiftUI
import UIKit

/// 专门用于 tvOS 播放页精确区分 Siri Remote 左/右键的「短按」与「长按（按住/松手）」
/// 当 isCaptureEnabled == false（例如弹出字幕设置抽屉或暂停菜单时）自动放行按键给 SwiftUI Focus Engine！
public struct RemoteKeyCaptureView: UIViewControllerRepresentable {
    public var isCaptureEnabled: Bool
    public var onShortPress: (ScrubDirection) -> Void
    public var onLongPressBegan: (ScrubDirection) -> Void
    public var onLongPressEnded: () -> Void
    public var onPlayPause: () -> Void
    public var onMenu: () -> Void

    public func makeUIViewController(context: Context) -> KeyCaptureViewController {
        let vc = KeyCaptureViewController()
        vc.coordinator = context.coordinator
        return vc
    }

    public func updateUIViewController(_ uiViewController: KeyCaptureViewController, context: Context) {
        context.coordinator.parent = self
        uiViewController.isCaptureEnabled = isCaptureEnabled
    }

    public func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    public final class Coordinator {
        var parent: RemoteKeyCaptureView
        init(parent: RemoteKeyCaptureView) { self.parent = parent }
    }

    public final class KeyCaptureViewController: UIViewController {
        weak var coordinator: Coordinator?
        var isCaptureEnabled: Bool = true
        private var holdTimer: Timer?
        private var activeDirection: ScrubDirection?
        private var didTriggerLongPress: Bool = false
        private let longPressThreshold: TimeInterval = 0.22 // 220ms 判定为长按

        public override var canBecomeFirstResponder: Bool { true }

        public override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
            guard isCaptureEnabled, let press = presses.first else {
                super.pressesBegan(presses, with: event)
                return
            }
            switch press.type {
            case .rightArrow, .leftArrow:
                let dir: ScrubDirection = (press.type == .rightArrow) ? .forward : .backward
                activeDirection = dir
                didTriggerLongPress = false
                holdTimer?.invalidate()
                holdTimer = Timer.scheduledTimer(withTimeInterval: longPressThreshold, repeats: false) { [weak self] _ in
                    Task { @MainActor in
                        guard let self, let d = self.activeDirection else { return }
                        self.didTriggerLongPress = true
                        self.coordinator?.parent.onLongPressBegan(d)
                    }
                }
            case .playPause:
                coordinator?.parent.onPlayPause()
            case .menu:
                coordinator?.parent.onMenu()
            default:
                super.pressesBegan(presses, with: event)
            }
        }

        public override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
            handlePressRelease(presses: presses, event: event, isCancelled: false)
        }

        public override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
            handlePressRelease(presses: presses, event: event, isCancelled: true)
        }

        private func handlePressRelease(presses: Set<UIPress>, event: UIPressesEvent?, isCancelled: Bool) {
            guard let press = presses.first, press.type == .rightArrow || press.type == .leftArrow else {
                if isCancelled { super.pressesCancelled(presses, with: event) }
                else { super.pressesEnded(presses, with: event) }
                return
            }
            holdTimer?.invalidate()
            holdTimer = nil
            if didTriggerLongPress {
                coordinator?.parent.onLongPressEnded()
            } else if !isCancelled, let dir = activeDirection {
                coordinator?.parent.onShortPress(dir)
            }
            activeDirection = nil
            didTriggerLongPress = false
        }
    }
}
```
- **`MXScrubController` 行为要求**：
  1. `beginHold(direction:currentTime:duration:onPreviewFrame:)`：
     - 立刻静音播放器防爆音；
     - 按每 `130ms` 节流推进 `targetTime`，采用三段非线性加速曲线：
       - 按住 `0 ~ 1.5s`：每步 `2s`（约 15s/秒）
       - 按住 `1.5 ~ 4.0s`：每步 `6s`（约 45s/秒）
       - 按住 `> 4.0s`：每步 `16s`（约 120s/秒）
     - 每次推进前调用 `previewDecodeTask?.cancel()`（**Latest-Wins**），再调用播放引擎的 `seekToKeyframePreview(at: targetTime)`（只解单个 IDR 关键帧并立即刷新主画面！）；
  2. `endHold(onCommit:)`：取消节流任务，在最终 `targetTime` 执行精确 Seek 并恢复播放与音频；
  3. 同时在设置中支持切换「长按模式」：`mxLiveKeyframeScrub`（默认，实时跳关键帧变画）或 `continuousFastPlay`（按住时切 2x/3x/4x 连续倍速播放，松手恢复 1x）。

#### Step 2.4：实现 `PlayerEngineProtocol`、`KSEngineAdapter` 与 `DisplayModeCoordinator`
- **涉及文件**：
  - `Sources/PlaybackEngine/PlayerEngineProtocol.swift`
  - `Sources/PlaybackEngine/KSEngineAdapter.swift`
  - `Sources/PlaybackEngine/DisplayModeCoordinator.swift`
  - `Sources/PlaybackEngine/SubtitleOverlayView.swift`
- **具体要求**：
  1. **视频流统一通过 `LocalHTTPStreamProxy` 喂给播放器**：SMB 与 WebDAV 都先经 `ReadAheadStreamCache` + `LocalHTTPStreamProxy` 转为 `http://127.0.0.1:<port>/stream/...`，播放器无需感知底层 SMB/WebDAV 细节。
  2. **`KSEngineAdapter` 配置要点**：
     - 开启 VideoToolbox 硬件解码（`hardwareDecode = true`）；
     - 启用 `AVSampleBufferDisplayLayer` 渲染管线，支持原生输出 HDR10 / HLG / Dolby Vision；
     - 暴露 `seekToKeyframePreview(at seconds: TimeInterval)` 方法（在 KSPlayer/FFmpeg 层使用关键帧快速跳转 `AVSEEK_FLAG_BACKWARD` 并快速出帧，供 `MXScrubController` 调用）；
     - 实时采集 `PlaybackStats`（视频编码、分辨率、动态范围、FPS、掉帧数、当前缓存秒数、局域网读取速度 Mbps、App 内存占用 MB）。
  3. **`DisplayModeCoordinator`**：
     - 通过 `UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first?.windows.first?.avDisplayManager` 获取 `AVDisplayManager`；
     - 播放起播获取到真实帧率与动态范围后设置 `preferredDisplayCriteria`；退出播放页面 `onDisappear` 时将 `preferredDisplayCriteria` 重置为 `nil`，确保干净退回 4K 60Hz SDR 桌面。
  4. **`SubtitleOverlayView`（独立可定制字幕渲染层）**：
     - 对于 SRT / VTT 以及开启了 `overrideASSStyles == true` 的 ASS 字幕，直接使用 SwiftUI/CoreText 叠层实时渲染 `SubtitleParser.activeCues(at:delay:)`；
     - 完全响应式绑定 `SubtitleStyleConfig`：位置（`padding(.bottom, screenHeight * bottomOffsetRatio)`）、字号（`.font(.system(size: fontSize, weight: weight))`）、颜色与不透明度（`.foregroundStyle(Color(hex: textColorHex).opacity(textOpacity))`）、描边与阴影、半透明圆角背景框；
     - 当播放含特效 ASS 且 `overrideASSStyles == false` 或播放 PGS 蓝光图形字幕时，交由底层引擎（KSPlayer / libass）渲染图形字幕，同时仍同步应用位置与延迟参数。
- **Phase 2 门禁**：
  - `git push` -> GitHub Actions 编译通过并生成 `AuraTV-Unsigned.ipa`；
  - 用 `atvloadly` 安装到 Apple TV 4K 真机，用一个硬编码测试 SMB/WebDAV 视频地址验证：**画面正常播放 + HDR/帧率切换正常 + 长按方向键画面实时跟着变 + 外挂字幕成功加载**。

---

### Phase 3：打造精美原生 tvOS UI（无海报墙，专注影院级体验）

> **阶段目标**：将全部核心能力组装为高颜值、遥控器交互丝滑的原生 tvOS App。

#### Step 3.1：建立 `DesignSystem`（Liquid Glass + 影院暗色主题）
- **涉及文件**：
  - `Sources/TVApp/DesignSystem/AdaptiveGlassSurface.swift`（`#available(tvOS 26.0, *)` 用 `.glassEffect(.regular, in: .rect(cornerRadius:))`，低版本降级 `.ultraThinMaterial` + 细高光描边）
  - `Sources/TVApp/DesignSystem/TVTheme.swift`（深空暗色渐变背景 `#0B0E14 -> #141923`、安全边距 `horizontalPadding = 80`, `verticalPadding = 60`、高对比度文字色）
  - `Sources/TVApp/DesignSystem/VideoBadgeParser.swift`（纯正则从文件名提取显示徽章：`4K` / `1080p` / `Dolby Vision` / `HDR10` / `HEVC` / `AV1` / `Atmos` / `TrueHD` / `DTS`，让纯文件列表也能一眼看出片源规格！）

#### Step 3.2：实现 `HomeView` 与 `SourceManagerView`（首页 + 局域网管理与测速）
- **涉及文件**：
  - `Sources/TVApp/Features/Home/HomeView.swift`
  - `Sources/TVApp/Features/Sources/SourceEditorView.swift`
  - `Sources/TVApp/Features/Sources/SpeedTestView.swift`
- **布局与交互要求**：
  - 顶部极简导航栏：`首页` | `网络源` | `设置`；
  - **首页分 3 个横向焦点区块**（每块使用 `.focusSection()` 防止焦点跳飞）：
    1. **继续观看**：展示最近播放的视频文件卡片（玻璃底框 + 底部播放进度条 + 剩余时长 + 规格徽章），点按直接断点续播；
    2. **已添加的网络源**：SMB / WebDAV 大卡片（支持长按或菜单键编辑/删除/测速）；
    3. **局域网自动发现**：实时显示 `BonjourDiscoveryService` 扫到的局域网 SMB/NAS 主机，点按一键带入 IP 添加。
  - **测速面板**：选中任一视频文件一键测 20MB 顺序读取速度，显示实时进度与最终 Mbps（如 `685 Mbps — 流畅支持 4K 蓝光原盘`）。

#### Step 3.3：实现 `FileBrowserView`（精致暗色玻璃文件浏览器）
- **涉及文件**：`Sources/TVApp/Features/Browser/FileBrowserView.swift`
- **布局与交互要求**：
  - 顶部面包屑路径 + 排序切换（名称 / 修改时间 / 文件大小）+ 仅看视频过滤开关；
  - 玻璃卡片式列表（`LazyVStack`）：每行左侧展示图标（文件夹 / 视频胶片图标），主标题清晰显示文件名，副行展示文件大小 + `VideoBadgeParser` 提取的 `4K / DV / HDR10 / HEVC` 胶囊徽章 + 若有观看记录则显示紧凑进度条与「上次看到 00:42:10」；
  - 右侧可选轻量详情预览栏（随当前聚焦文件平滑更新：完整文件名、大小、修改时间、同目录检测到的外挂字幕数量提示，如「已发现 2 个外挂字幕」）。

#### Step 3.4：实现 `PlayerScreenView`、MX 实时快进 HUD 与字幕实时样式抽屉
- **涉及文件**：
  - `Sources/TVApp/Features/Player/PlayerScreenView.swift`
  - `Sources/TVApp/Features/Player/PlayerHUDView.swift`
  - `Sources/TVApp/Features/Player/SubtitleSettingsDrawer.swift`
  - `Sources/TVApp/Features/Player/AudioAndEngineDrawer.swift`
- **交互细节要求（务必严格落实）**：
  1. **起播流程**：打开视频 -> 后台异步并行触发 `SubtitleMatcher` 扫描同目录 + `Subs/` 目录并自动挂载首选外挂字幕（屏幕左上角弹 2 秒轻提示：`已自动加载外挂字幕：xxx.chs.ass`）。
  2. **MX 长按快进浮层**：
     - 长按右/左键时，不弹出厚重的底部大菜单，仅在画面中上部/底部显示紧凑 Liquid Glass 药丸：`>>> +01:25  |  00:54:12 / 02:18:00` + 细进度条，**让 90% 以上电视画面完全露出，用户清晰看着画面实时飞速变化**；
     - 松手后 0.8 秒自动淡出浮层。
  3. **字幕样式实时调节抽屉（右侧 38% 宽度半透明玻璃抽屉，不遮主画面中央与底部字幕区！）**：
     - 打开该抽屉时，`RemoteKeyCaptureView.isCaptureEnabled` 设为 `false`，方向键自然操作抽屉控件，**同时视频保持播放（或暂停在含字幕的画面）**，用户每按一下遥控器即可亲眼看到电视画面上的字幕实时上下移动、变大变小、换色、调透明度！
     - 抽屉内提供以下 9 项直观控件：
       1. 字幕轨选择（内封轨道 + 自动发现的外挂字幕 + 「浏览文件夹手动选字幕」+ 关闭字幕）
       2. **垂直位置**（`0% ~ 35%`，±1% 精细微调）
       3. **字号大小**（`32pt ~ 96pt`，±2pt 步进）
       4. **文字颜色**（纯白 / 电影黄 / 护眼暖白 / 冰蓝 / 浅绿 色块一键选）
       5. **文字不透明度**（`40% ~ 100%`，HDR 防刺眼）
       6. **字体粗细**（细 / 常规 / 半粗 / 粗体）
       7. **描边粗细**（`0 ~ 6`）与 **半透明背景框**（`0% ~ 80%`）
       8. **时间轴同步偏移**（`-10s ~ +10s`，±0.1s 步进，附带归零按钮）
       9. **强制覆盖 ASS 样式开关**（ON/OFF）
     - 所有调整实时自动写入 `AppPreferences`，下次看任何片子自动沿用！
  4. **音轨与引擎抽屉**：切换多音轨、切换解码模式（硬件/软件，及 Phase 4 扩展的 KSPlayer/MPVKit 切换）、开启/关闭左上角实时性能监视器（编码/分辨率/HDR/FPS/掉帧/读取 Mbps/内存 MB）。

---

### Phase 4：备核扩展（MPVKit）、性能调优与最终真机验收

#### Step 4.1：按需挂载 `MPVKit` 备核（应对极端特效 ASS 与冷门封装）
- 在 `project.yml` 补充 `MPVKit`（或预编译 `libmpv` tvOS XCFramework），实现 `Sources/PlaybackEngine/MPVEngineAdapter.swift` 遵循同一套 `PlayerEngineProtocol`，在设置页开放「默认解码核切换：KSPlayer（推荐 HDR/DV） / MPVKit（推荐动漫特效字幕）」。

#### Step 4.2：全链路真机终验收清单（逐项勾稽通过方可结项）

| 序号 | 验收项 | 操作步骤 | 必须达到的结果 |
| :--- | :--- | :--- | :--- |
| 1 | **Ubuntu 自动化单测** | 在 `192.168.5.157:/data/projects/AuraTV/Packages/MediaCoreKit` 运行 `swift test` | 全部用例 100% PASS，无崩溃、无并发警告 |
| 2 | **CI 自动化产包** | `git push` 触发 GitHub Actions | `core-tests-ubuntu` 与 `build-tvos-unsigned-ipa` 全绿，产出 `AuraTV-Unsigned.ipa` |
| 3 | **无线部署与续签** | `192.168.5.157:5533` (`atvloadly`) 推送到 Apple TV 4K | 无线安装成功，后台自动续签任务显示正常 |
| 4 | **SMB / WebDAV 连接** | 添加局域网 SMB（如 `192.168.5.229`）与 WebDAV 源，执行测速与目录浏览 | Bonjour 自动发现正常；SMB 千兆有线读取 ≥ 300 Mbps；WebDAV 302 跳转直链起播稳定 |
| 5 | **全格式与画质音频** | 依次播放 4K 10-bit HEVC HDR10/Dolby Vision、AV1、H.264、TrueHD 7.1、DTS-HD MA | 电视准确点亮 HDR/Dolby Vision 徽标并切换 24Hz；退出恢复 4K 60Hz SDR；音频多声道 LPCM 正常同步 |
| 6 | **外挂字幕自动与定制** | 播放带同目录 GBK `.srt` 和 `Subs/` 下 `.ass` 字幕的视频；在播放中打开字幕抽屉调位置、大小、颜色、不透明度、延迟与 ASS 覆盖 | 自动无乱码挂载首选简体中文外挂字幕；调节时主画面字幕**即时变化**；退出重进后偏好完整保留 |
| 7 | **MX 风格长按实时快进** | 在 4K 大码率视频中短按与长按 Siri Remote 左/右键 | 短按精准 ±10s；**长按时全屏主画面以 ≥ 6fps 实时跟着变化、非线性平滑加速、无爆音、松手 < 0.8s 恢复音画同步** |
| 8 | **UI 与内存稳定性** | 连续切换 10 部 4K 大文件并高频长按快进，同时检查性能监视器 | 遥控器焦点永不走丢；界面 60fps 流畅；内存峰值稳定在 **< 1.2 GB**，无闪退 |

---

## 四、给执行 AI 的交接汇报格式模板

每次完成一个 Step 或 Phase 后，执行 AI 必须按以下格式向用户汇报，便于核查进度：

```markdown
### 已完成：Step X.Y - <步骤名称>
- **新增/修改文件**：列出精确绝对路径
- **执行命令与验证结果**：贴出 `swift test` 或 GitHub Actions 运行链接与关键结果摘要
- **已知问题/需要人工配合项**：例如需要用户在 Apple TV 核对配对 PIN 码、提供测试 WebDAV 地址等
- **下一步计划**：Step X.Z - <下一步名称>
```
