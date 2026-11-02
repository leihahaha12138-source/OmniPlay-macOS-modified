# 觅影 OmniPlay · macOS 修改版

> **上游项目：[nandieling/OmniPlay](https://github.com/nandieling/OmniPlay)**
>
> 本仓库是它的个人修改版，**只保留 macOS Apple Silicon（arm64）分支**。
> 基于上游 **1.7**（commit `2fec8c8`）。原许可证、署名与版权声明均完整保留。
>
> **绝大部分功能与代码都是原作者的工作。** 这里只按自己的使用习惯做了四处改动，
> 并且只在 macOS 26 / Apple Silicon 上验证过。

---

## 改了什么

### 1. 去掉 TMDB，换成豆瓣

- 关闭了所有 TMDB 相关的界面与请求（设置项、评分徽章、详情页星级、搜索弹窗、刮削流程）。
  **代码没有删**，一个总开关 `SettingsView.showTMDBSettings` 统一控制，改回 `true` 即恢复。
- 评分、海报、简介改由豆瓣提供：海报与简介写进 `movie.posterPath` / `doubanMetadata`，
  详情页优先显示豆瓣评分。
- **App 内直接登录豆瓣**：设置页点一下，弹出官方登录页扫码，登录成功后自动把 cookie
  存到 `~/.omniplay-douban-sync/douban-cookie.txt`（权限 0600），
  省去「开浏览器 → 开发者工具 → 复制 cookie」那一套。
- 自动刮削由配套脚本 `douban-sync/` 完成（独立进程，见它自己的 README）。
  脚本支持中文优先的片名候选词、年份消歧、失败冷却，并对豆瓣做了限速（≥12 秒一次）。
- 脚本写完数据库后会发一条系统通知，海报墙立刻刷新，不用重启 App。

> 说明：豆瓣只对**手动绑定**提供官方入口，本仓库的自动刮削是额外补的。
> 写入的是本地 SQLite（等价于帮你在 App 里逐条手动绑定），写库前会自动备份。

### 2. 修复 ⌘Q 退出不保存播放进度

之前退出时写库放在异步任务里，进程先终止，任务从未执行 —— 表现为「必须点叉退回主页才存得上」。
改为在终止路径上用同步写库，⌘Q 也能记住进度。

### 3. 修复全屏 ↔ 小窗切换后画面被裁切

MoltenVK 只在视频加载那一刻读一次图层尺寸，之后不再感知窗口 resize，
于是退出全屏时 mpv 仍按全屏尺寸绘制，画面只露出左上角一块。

修法是重建视频输出（`vid=no` → `vid=auto`），让它重新读取图层尺寸；
按「全屏切换 0.15s / 手动拖拽 0.6s」分别防抖。
思路来自 MPVKit 官方 demo 的 `enterBackground()` / `enterForeground()`。
代价是重建瞬间会有一帧黑屏。

### 4. 顺带修的几处

- 豆瓣登录页白屏（豆瓣账号中心换了域名）、登录成功却显示未登录、
  点登录 1 秒自动关闭（WebView 里残留旧 cookie）等一串问题。
- 扫描时写入的「正在排队等待刮削…」占位文案会永久留在详情页（因为 TMDB 关掉后没人来替换），
  已改为回退显示豆瓣简介。
- 新增 `DiagLog`：把播放器、渲染层、通知链路的关键信息落到
  `~/Library/Logs/OmniPlay-Debug/diag.log`，方便排查问题。

---

## 编译

需要 Xcode（含 macOS SDK）。

```bash
open OmniPlay.xcodeproj      # 直接 Run
```

或命令行：

```bash
xcodebuild -project OmniPlay.xcodeproj -scheme OmniPlay \
  -configuration Debug -sdk macosx build
```

- 播放内核是 **MPVKit 0.41.0**（`Package.resolved` 里锁定），首次编译会从 GitHub 拉取
  它的 xcframework —— **依赖目录解压后约 1.6 GB**，网速一般的话要等几分钟。之后增量编译 10–40 秒。
- `GRDB.swift-master` 是仓库内的本地 Swift 包，不要删。
- Bundle ID 沿用上游的 `nan.OmniPlay`，以便覆盖安装；想和原版并存请自行修改。

实测（Apple Silicon / Xcode 26）：

| 场景 | 结果 |
|---|---|
| 全新克隆 + 空依赖缓存 + 空 DerivedData | **2 分 47 秒**，`BUILD SUCCEEDED`，产物 84 MB（Debug） |
| 同机增量编译 | 10–40 秒 |
| `-configuration Release` | 59 秒，产物 **64 MB** |

> 想发给别人用请用 **Release**，不要发 Debug（体积大、性能低）。

---

## 它不做什么

- **只支持 macOS Apple Silicon。** 上游的 Windows / Android TV / Docker / x64 分支已从本仓库移除，
  需要的话请去[上游](https://github.com/nandieling/OmniPlay)。
- **不提供 TMDB API Key，也不内置任何公共 Key。**
- 不做剧集/分集剧照（本项目按只看电影的场景改的）。
- 不签名、不公证。自编译产物在本机运行即可，分发给别人需要自己处理签名。

---

## 免责声明

- 本项目与**豆瓣（北京豆网科技有限公司）没有任何关联**，不是官方客户端，也未获其授权或认可。
  「豆瓣」二字仅用于说明本软件读取的数据来源。
- 自动刮削使用的是**你自己的账号、你自己的登录态**：在 App 内加载的是豆瓣官方登录页，
  不注入脚本、不读取密码、不绕过任何验证码或访问控制。凭据只存在本机（权限 0600），不外发。
- 但请自行确认这种用法符合豆瓣的用户协议。**本项目不鼓励高频访问**，
  脚本默认 ≥12 秒一次并带失败冷却与熔断，建议只在自己确实要看的时候跑。
- 仅供个人学习与自用，请勿用于商业用途，也不要用它批量转载豆瓣的内容。
- 本项目按「现状」提供，不附带任何担保。

---

## 许可与致谢

- 许可证：[AGPL-3.0](./LICENSE)，沿用上游，未做改动。
- 原始作者：[nandieling](https://github.com/nandieling)，以及上游 README 中列出的所有贡献者。
- 本仓库的修改同样以 AGPL-3.0 发布。修改内容即本 README 第 1–4 节。
- 上游已明确同意基于其代码二次开发与公开发布。
