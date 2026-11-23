# AuraTV 安装到 Apple TV 4K（tvOS 27）完整保姆级指南

本指南适用于**个人自用 + 免费 Apple ID（无 \$99 付费开发者账号）+ Apple TV 4K (tvOS 27)**，全程无需 Mac 电脑，也不需要安装 macOS 虚拟机。

---

## 一、获取编译好的安装包（`AuraTV-Unsigned.ipa`）

1. 在 `192.168.5.157` 上将代码推送到你的 GitHub 仓库（公开或私有仓库均可）：
   ```bash
   cd /data/projects/AuraTV
   git remote add origin <你的GitHub仓库URL>
   git push -u origin main
   ```
2. 用电脑浏览器打开你的 GitHub 仓库 -> 点击顶部 **Actions** -> 进入最新一次运行 **`AuraTV CI (Ubuntu Tests + tvOS 27 Unsigned IPA & Preview)`**。
3. 等待两个绿色对勾完成（约 3~5 分钟）：
   - `core-tests-ubuntu`（Ubuntu 核心库单测）
   - `build-tvos-unsigned-ipa`（Apple Silicon `xcode-27` 编译打包）
4. 滑到页面最底部 **Artifacts** 区域，点击下载 **`AuraTV-Unsigned-tvOS-IPA`**，解压得到 **`AuraTV-Unsigned.ipa`** 文件。
   *(提示：如需先在 Windows 浏览器预览 UI 截图，可在 Actions 页面点 `Run workflow` 触发 `preview-tvos-screenshots` 下载 PNG 截图。)*

---

## 二、准备自动续签服务（二选一，推荐最终放到不关机的 OpenWrt）

免费 Apple ID 签名的 App 每 **7 天** 会过期一次，通过 **`atvloadly`** 可在局域网后台**每 7 天全自动无感续签**，实现接近永久有效：

### 方案 A：直接使用已部署好的 `192.168.5.157`（现在就能用！）
- 服务已部署并启动完毕，浏览器直接访问：**`http://192.168.5.157:5533`**。

### 方案 B：部署到 24 小时不关机的 OpenWrt 路由器（推荐长期使用）
- 确认你的 OpenWrt 为 `x86_64` 或 `arm64` 架构、已装 Docker 且有 ≥ 300MB 持久化目录（例如 `/mnt/data`）。
- 将仓库中的 `Scripts/deploy/openwrt-atvloadly.sh` 拷到 OpenWrt 上执行：
  ```sh
  sh openwrt-atvloadly.sh /mnt/data/atvloadly
  ```
- 部署完成后访问：**`http://<OpenWrt局域网IP>:5533`**。
- *无损迁移提示*：如果你先在 `192.168.5.157` 配对好了，以后想迁到 OpenWrt，停掉旧容器并把 `/data/atvloadly` 整个目录拷贝到 OpenWrt 的 `/mnt/data/atvloadly` 启动即可，无需重新配对！

---

## 三、无线配对 Apple TV 4K 并一键安装（约 2 分钟）

> **前提检查**：确保 Apple TV 4K 与 `atvloadly` 所在设备处于**同一个局域网网段**（例如都在 `192.168.5.x`），路由器未开启 AP 隔离。

1. **打开 Apple TV 进入配对界面**：
   - 拿起 Siri Remote，在 Apple TV 上依次进入：
     **设置（Settings） -> 遥控器与设备（Remotes and Devices） -> 遥控器 App 与设备（Remote App and Devices）**
   - 保持停留在当前页面（不要退出）。
2. **在网页端配对 Apple TV**：
   - 电脑浏览器打开 **`http://192.168.5.157:5533`**（或你的 OpenWrt 地址）；
   - 点击 **添加/扫描设备（Pair / Devices）**，页面会自动通过 Avahi mDNS 发现你的 Apple TV 4K；
   - 点击配对 -> 电视屏幕上会弹出 **4 位或 6 位配对 PIN 码** -> 在网页输入该 PIN 码，提示配对成功。
3. **添加免费 Apple ID**：
   - **安全建议**：专门注册/使用一个**备用免费 Apple ID**（不要用存有大量照片/支付信息的主力 iCloud 账号）；
   - 在 `atvloadly` 的 **Apple ID / 账号管理** 页面登录该账号，按提示输入双重认证（2FA）6 位验证码。
4. **上传并安装 `AuraTV-Unsigned.ipa`**：
   - 进入 **安装 / Sideload** 页面 -> 选定刚才配对好的 Apple TV 4K 与免费 Apple ID；
   - 上传第一步下载解压的 **`AuraTV-Unsigned.ipa`** -> 点击安装；
   - 等待约 15~30 秒（完成签名与局域网无线传输），**Apple TV 桌面立刻出现 `AuraTV` 图标**！
5. **开启自动续签**：
   - 在 `atvloadly` 的已安装 App 列表中确认 `AuraTV` 的 **自动续签（Auto Refresh）** 开关为开启状态。之后只要 Apple TV 保持通电连网（休眠状态亦可唤醒续签）且 `atvloadly` 所在机器在线，系统会自动在 7 天到期前后台续签。

---

## 四、常见问题排查（FAQ）

1. **网页里扫不到 Apple TV？**
   - 确认 Apple TV 当前停留在 `设置 -> 遥控器与设备 -> 遥控器 App 与设备` 界面；
   - 确认宿主机 `avahi-daemon` 运行正常（`systemctl is-active avahi-daemon` 或 OpenWrt `/etc/init.d/avahi-daemon status`）；
   - 如果 Apple TV 和服务器跨 VLAN / 路由器开了组播隔离，需要把两者放到同一局域网广播域。
2. **提示 `Maximum number of apps for free development profiles has been reached`？**
   - 免费 Apple ID 在同一台 Apple TV 上最多同时激活 **3 个**自签侧载 App。卸载掉其他不用的自签 App，或换一个备用免费 Apple ID 即可。
3. **7 天后点开 App 闪退？**
   - 说明续签时 Apple TV 彻底断电或 `atvloadly` 所在电脑关机了；打开 `atvloadly` 网页手动点一下 **立即刷新（Refresh）** 即可秒恢复，**所有播放记录、网络源和字幕样式设置都不会丢失**。
4. **后续有新版本怎么升级？**
   - 只需从 GitHub Actions 下载新的 `AuraTV-Unsigned.ipa`，在 `atvloadly` 上传覆盖安装即可，本地配置与观看记录自动保留。
