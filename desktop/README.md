# 鲸鱼娘 · 跨平台桌面版（macOS + Windows）

这是 1.3.0 起的唯一实现：**Tauri 2 + Rust core + React**，macOS 与 Windows 共用。旧的 Swift/AppKit 版本已从仓库移除，只保留在 git 历史和 v1.2.0 Release 存档中。

## 为什么是 Tauri，而不是继续 Swift

真正和 macOS 绑定的只有四件事：透明置顶窗口、菜单栏、辅助功能跳转、pkg 更新。会话扫描、zstd 尾解压、状态机、token / 费用 / 额度统计都是纯逻辑。新架构把它们放进一个**没有 UI 依赖的 Rust crate**，macOS 用 WKWebView、Windows 用 WebView2 跑同一份 React UI：

```text
                 ┌─────────────────────────────────────────────┐
                 │  React + Vite (一份 UI)                      │
                 │  pet window · board window                  │
                 └───────────────▲─────────────────────────────┘
                                 │ invoke / events (JSON)
                 ┌───────────────┴─────────────────────────────┐
                 │  Tauri 2 shell (Rust)                       │
                 │  windows · tray · hit-test · control server │
                 │  settings · deep links · clipboard          │
                 └───────────────▲─────────────────────────────┘
                                 │ FleetView
                 ┌───────────────┴─────────────────────────────┐
                 │  whalegirl-core (Rust, no UI)                │
                 │  DSH ─ Codex ─ OpenCode ─ AgentMonitor       │
                 │  zstd tail · SQLite · cost ledger · quota    │
                 └─────────────────────────────────────────────┘
```

- **一份解析逻辑**：`core/` 不依赖 Tauri，`wg-dump` CLI 和桌面壳共用。
- **一份前端**：宠物立绘、气泡、任务面板都是 HTML/CSS/SVG；不再手写 AppKit 绘制。
- **纯 Rust zstd**：不再需要 `zstd-helper` 子进程或 Homebrew 静态库。
- **bundled SQLite**：Windows 上不需要系统 SQLite。
- **安装包更小**：macOS 用 WKWebView、Windows 用 WebView2，不再打包整个浏览器内核。

## 目录

```text
desktop/
  core/                       # whalegirl-core：跨平台监控核心
    src/models.rs             # AgentSession / FleetView / Usage
    src/logtail.rs            # zstd frame 尾读 + JSONL
    src/providers/dsh.rs      # ~/.dsh/sessions + dsh-cost-meter
    src/providers/codex.rs    # ~/.codex/sessions/**/rollout-*.jsonl
    src/providers/opencode.rs # ~/.local/share|LOCALAPPDATA/opencode/opencode.db
    src/monitor.rs            # 1.5s 轮询、Provider 汇总
    src/paths.rs              # macOS / Windows 数据目录解析
    src/bin/wg_dump.rs        # 诊断 CLI（对齐 Swift --dump）
  src-tauri/                  # Tauri 壳（窗口 / 托盘 / 命令）
    src/state.rs              # 设置、窗口位置、监控线程、点击穿透
    src/platform.rs           # 鼠标命中、剪贴板、打开目录、激活 DSH
    src/menu.rs               # 托盘菜单 + 右键菜单
    src/control.rs            # 127.0.0.1:47113 控制端口
    tauri.conf.json           # 双窗口、透明、置顶、深链、打包
  src/                        # React UI
    components/Pet.tsx        # 立绘动作、气泡轮播、拖动、散步
    components/Board.tsx      # 深海任务台
    lib/format.ts             # 文案 / 时间 / token 格式化
    lib/api.ts                # Tauri command 封装（浏览器里有 demo 数据）
    styles.css                # 与旧版一致的深海配色
```

## 本地开发

要求：macOS 13+ / Windows 10 1809+（WebView2）。

- macOS：Xcode Command Line Tools（`swiftc` 不需要，但 WebKit 链接需要 CLT）
- Windows：Visual Studio Build Tools（C++ 桌面负载）+ WebView2 Runtime（Win10/11 一般自带）
- Node.js 20+、pnpm 9+
- Rust stable（1.82+，`rust-version` 在根 Cargo.toml）

```bash
cd desktop
pnpm install
pnpm tauri dev          # 开发模式，自动启动 Vite
pnpm tauri build        # 打本机安装包（macOS: .app/.dmg；Windows: .msi/.exe）
pnpm tauri build --bundles app   # 只出 .app，适合快速验证 / 受限沙箱里跳过 hdiutil
```

只跑核心 / 前端：

```bash
cargo test -p whalegirl-core
cargo run -p whalegirl-core --bin wg-dump -- --json   # 与 Swift --dump 同源数据
pnpm build                                            # tsc + vite
```

> `desktop/.cargo/config.toml` 把 crates.io 指到了 rsproxy 镜像（本机直连 crates.io 会超时）。如果你的网络能直连，删掉这个文件即可；CI 里也使用它，rsproxy 在 GitHub Actions 上可用。

## 两端的差异与处理

| 能力 | macOS | Windows | 说明 |
| --- | --- | --- | --- |
| 透明无边框置顶窗 | WKWebView + `transparent` | WebView2 + `transparent` | 两边都关闭系统阴影，圆角/发光由 CSS 画；`LSUIElement` + Accessory 让 macOS 不出现 Dock/菜单栏 |
| 逐像素点击穿透 | `NSWindow.ignoresMouseEvents` | `set_ignore_cursor_events` | Rust 每 70ms 用全局鼠标位置和前端上报的可交互矩形求交；拖动时强制接收事件；位置约束在 Dock/任务栏之外的 work area |
| 托盘 | 菜单栏 item | 通知区域图标 | 同一套原生菜单：面板 / 暂停 / 提示音 / 散步 / 摔跤 / 大小 / 更新 / 重置 / 隐藏 / 退出 |
| 开机自启 | 登录项 | 启动项 | 这一版先由 DSH 插件 / 用户在系统里设置，未接 `tauri-plugin-autostart` |
| 控制端口 | `127.0.0.1:47113` | 同左 | 兼容旧 DSH 插件的 `/status` `/toggle` `/show` `/hide` `/recenter` `/quit` |
| 深链 | `bluefish://` | 同左 | 由 `tauri-plugin-deep-link` 注册；`size/0.75`、`toggle`、`show`、`hide`、`recenter`、`board`、`check-update` |
| 会话跳转 | 复制会话名 + 激活 DSH | 复制会话名 | AX 精确跳转还没移植；Windows 上 DSH 没有稳定入口，降级为复制 |
| 数据目录 | `~/.dsh`、`~/.codex`、`~/.local/share/opencode` | `%USERPROFILE%\.dsh`、`%USERPROFILE%\.codex`、`%LOCALAPPDATA%\opencode` | `paths.rs` 会优先选真正存在 `opencode.db` 的候选目录 |
| zstd | 纯 Rust `zstd` | 同左 | 不再编译/签名 helper |
| SQLite | bundled `rusqlite` | bundled `rusqlite` | 只读打开，WAL 被占用时退化为空状态 |
| 费用 / 额度 | 本地 ledger + OpenCode 接口 | 同左 | 网络请求只在 OpenCode Go 账号存在时发生，可用设置关掉 |
| 自动更新 | 旧版 pkg + SHA256 | 旧版无 | 新版还没接签名通道；见下面“已知缺口” |

## 设置与状态

- 设置：`app_config_dir/settings.json`（macOS `~/Library/Application Support/com.daiwei.whalegirl/`，Windows `%APPDATA%\com.daiwei.whalegirl\`）
  - `petScale`、窗口位置、`sounds`、`wander`、`dropTumble`、`paused`、`opencodeFetchQuotas`、`opencodePlan`、`boardChannel`、`bubbleCollapsed`
- DSH 插件可见状态：仍然写 `~/.dsh/storages/bluefish-pet.json`，字段 `visible` / `pid` / `updatedAt` / `platform`。
- 控制端口返回 `{"ok":true,"running":true,"visible":bool,"board":bool,"platform":"macos|windows"}`；额外有 `GET /debug`（窗口几何 / 设置 / 命中矩形）和 `GET /scale/0.75` 便于诊断。

## 点击穿透是怎么做的

1. 前端把“立绘 + 气泡 + 状态条”的并集矩形按 CSS 像素上报给 Rust（`report_hit_rect`）。
2. Rust 每 70ms 读全局鼠标位置：
   - macOS：主线程里取 `NSWindow.frame` 与 `NSEvent.mouseLocation`（都是屏幕坐标、左下原点），转成窗口内左上坐标；
   - Windows：`GetCursorPos` + `GetWindowRect`，除以窗口 DPI scale，得到 CSS 像素。
3. 光标在矩形内 → `set_ignore_cursor_events(false)`，否则 `true`；拖动期间强制为 `false`，松手后恢复。
4. 这样透明边距不会挡住底下的 DSH / 浏览器，只有真正画着宠物的区域接收点击。

## 测试

```bash
# Rust core：19 个单测（日志解析、状态机、token、额度、路径、zstd、SQLite、权限）
cargo test -p whalegirl-core

# 完整 FleetView JSON（与桌面壳消费的是同一份数据）
cargo run -p whalegirl-core --bin wg-dump -- --json
```

历史验证（旧 Swift 版已移除）：同一时刻 DSH 18 个会话、¥5.5714、444 次调用、配额 3% / 1% / 18% 一致。

## 已知缺口 / 下一步

1. **DSH AX 精确跳转**：目前复制会话名 + 激活 DSH；移植需要在 macOS 用 ApplicationServices，Windows 用 UI Automation。
2. **自动更新**：Tauri updater 需要 ed25519 签名密钥和 `latest.json` 发布通道；macOS 还需要 Developer ID 签名 + 公证。当前菜单里的“检查更新”会提示手动下载。
3. **开机自启**：接 `tauri-plugin-autostart`，托盘菜单增加开关；DSH 插件的 `autoStart` 在 Windows 上也需要改成可配置路径。
4. **菜单栏状态色点**：新版托盘已经是鲸鱼剪影（macOS 模板图标 / Windows 青色图标），但没有旧版右下角的 mood 色点；可在 Rust 里用 `image` 合成 16×16 色点。
5. **非激活窗口**：旧版 `NSPanel` 点击不抢焦点；Tauri 窗口默认点击会激活。macOS 可以用 `NSWindow` 非激活样式，Windows 可以加 `WS_EX_NOACTIVATE`，需要在 `platform.rs` 做平台补丁。
6. **Windows 实机验证**：DPI 150/200%、多显示器、任务栏在左/上、WebView2 缺失提示、NSIS/MSI 安装路径都需要在 Windows 上跑一遍。
7. **提示音**：目前用 WebAudio 合成短音；旧版用 `NSSound` 系统音。若需要完全一致，可加 Rust 命令播放系统音。
8. **CI 签名**：`.github/workflows/desktop.yml` 只出未签名安装包；发布前配置 Apple Developer ID / Windows 代码签名 secrets。
9. **DSH 插件**：`dsh-bluefish-pet 1.1.3+` 已支持 macOS/Windows 和自定义目录；npm 上仍是 1.0.1，需要从 GitHub 安装。

## 发布

```bash
cd desktop
pnpm tauri build
# macOS: target/release/bundle/dmg/*.dmg
# Windows: target/release/bundle/nsis/*.exe
```

GitHub Actions 矩阵（macos-14 arm64 + windows-latest）见仓库根 `.github/workflows/desktop.yml`。

## 旧版

- Swift/AppKit 实现已在 1.3.0 后移除；`v1.2.0` Release 和 git 历史仍可查。
- 不要同时运行旧 `WhaleGirl.app` 和新 `鲸鱼娘.app`：两者都监听 47113，后启动的控制端口会绑定失败。
- 立绘是 `@assets` 别名直接引用仓库根 `Assets/`，没有复制第二份。
