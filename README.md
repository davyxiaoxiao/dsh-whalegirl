# 鲸鱼娘 · macOS + Windows 桌面宠物

[下载 1.3.1](https://github.com/davyxiaoxiao/dsh-whalegirl/releases/tag/v1.3.1) · [DSH 插件](https://github.com/davyxiaoxiao/dsh-plugin-bluefish-pet)

<img src="preview.png" width="820" alt="鲸鱼娘桌面宠物与深海任务台" />

一只独立运行的透明桌宠：Q 版蓝发女仆、鱼鳍耳、小短腿；干饭时趴在桌上吃白米饭，被拖动时会迈步，松手会摔一跤再爬起来。它同时监控本地的编码代理：**DSH、Codex、OpenCode**。

从 **1.3.0** 起，macOS 和 Windows 共用同一套 **Tauri 2 + Rust + React** 实现；旧的 Swift/AppKit 版本已从仓库移除，仅保留在 git 历史和 [v1.2.0 Release](https://github.com/davyxiaoxiao/dsh-whalegirl/releases/tag/v1.2.0) 中存档。

## 功能

- **常驻桌面**：透明、无边框、置顶；macOS 逐像素点击穿透，Windows 当前整窗接收点击（透明边距会挡点击，后续恢复）。
- **任务看板**：点宠物打开「深海任务台」，按 DSH / Codex / OpenCode 渠道筛选，显示当前动作、步数、时长、今日 tokens、费用和 Go 套餐额度。
- **状态立绘**：待命 / 干饭 / 等你确认 / 出错 / 完成 / 睡觉 / 代理断连；完成时叉腰、出错时惊慌，带气泡、音效和粒子。
- **拖动 / 摔跤 / 散步**：拖动切换被拎起姿势，松手向下落到地面、翻肚皮、爬起来；空闲时自己左右散步。
- **多任务气泡**：多个任务时每 4.5 秒轮播；完成 / 出错 / 待确认优先。
- **托盘 / 菜单栏**：打开面板、暂停监控、提示音、散步、摔跤、宠物大小、检查更新、重置位置、隐藏、退出。
- **只读本地**：DSH `~/.dsh/sessions` 与 `dsh-cost-meter`、Codex `~/.codex/sessions`、OpenCode SQLite；不修改代理配置。
- **本地控制**：`127.0.0.1:47113` 控制端口、`bluefish://` 深链、原生右键菜单、设置持久化。

## 安装

- **macOS 13+（Apple Silicon）**：下载 `.dmg`，拖进「应用程序」。安装包为 ad-hoc 签名、未经 Apple 公证，首次启动右键 →「打开」→「打开」即可。
- **Windows 10/11 x64**：运行 NSIS 安装包；未签名，SmartScreen 选「更多信息 → 仍要运行」。

> **1.3.0 的 macOS 安装包已损坏**，1.3.1 已修复：1.3.0 的 `.app` 只有链接器写下的占位签名，没有封装资源签名，Apple Silicon 上会报「“鲸鱼娘”已损坏，无法打开」，右键「打开」也无效。1.3.1 在 `bundle.macOS.signingIdentity` 里显式要求 ad-hoc 签名，CI 也会用 `codesign --verify` 卡住同类产物。仍装着 1.3.0 的话，直接覆盖安装 1.3.1，或执行：
>
> ```bash
> xattr -cr "/Applications/鲸鱼娘.app"
> codesign --force --deep --sign - "/Applications/鲸鱼娘.app"
> ```

当前 1.3.1 资产：

```text
WhaleGirl-1.3.1-macos-arm64.dmg
WhaleGirl-1.3.1-win-x64-setup.exe
```

## 随 DSH 自启

安装跨平台版后手动启动一次，再安装插件：

1. DSH 插件页卸载旧版；
2. 安装来源填 `github:davyxiaoxiao/dsh-plugin-bluefish-pet`（1.1.3+）；
3. 重启 DSH。

插件会读 App 写下的真实 exe 路径，支持自定义目录（例如 `D:\新建文件夹\鲸鱼娘`）和 Windows 自启。npm 上的 `dsh-bluefish-pet` 仍是旧版 macOS-only，暂不要用 npm 名字装。

## 开发

```bash
cd desktop
pnpm install
pnpm tauri dev          # 开发
pnpm tauri build        # 打包
cargo test -p whalegirl-core
cargo run -p whalegirl-core --bin wg-dump -- --json
pnpm build
```

也可以用根目录 Makefile：

```bash
make dev
make build
make test
```

详细架构、Windows 差异、已知缺口见 [desktop/README.md](desktop/README.md)。

## 目录

```text
desktop/core        Rust 监控核心（无 UI 依赖）
desktop/src-tauri   Tauri 壳（窗口 / 托盘 / 点击穿透 / 控制端口）
desktop/src         React UI（宠物 + 任务面板）
Assets              立绘与图标
.github/workflows    macOS + Windows CI 与安装包
```

## 已知限制

- Windows 点击穿透暂时关闭，整窗会拦截点击；恢复需要原生 DPI 命中判定。
- AX 精确会话跳转未移植：目前复制会话名 + 激活 DSH。
- 自动更新签名通道、开机自启未接入。
- 安装包未签名，macOS Gatekeeper / Windows SmartScreen 会提示。
- 立绘为 DeepSeek 同人二创，仅作个人桌面装饰使用。
