# 鲸鱼娘 · DeepSeek Harness 桌面宠物

[下载安装包](https://github.com/davyxiaoxiao/dsh-whalegirl/releases) · [DSH 插件](https://github.com/davyxiaoxiao/dsh-plugin-bluefish-pet)

![preview](preview.png)

一只独立运行的 macOS 桌面宠物：**Q 版**蓝发女仆、小号鱼鳍耳、两条细腿（没有鱼尾）；干饭时趴在桌上吃白米饭，被你拖来拖去的时候会迈开小短腿走路。它顺便帮你盯着本地的编码代理——目前内置 DSH、Codex、OpenCode，费用和会话监控已经抽成适配器，后续接 Claude Code 只需要加一个 Provider。

它**不是 DSH 插件**，也不依赖 DSH 的窗口。DSH 最小化、切到别的 App、甚至只开着一个终端里的 `dsh`，小鱼都还在桌面上。

---

## 它现在会做什么

- **常驻桌面**：无边框、透明、置顶，所有 Space 可见；透明区域鼠标穿透，不会挡住正常点击。
- **可调大小**：右键宠物 →「宠物大小」，或点菜单栏小鱼的菜单 →「宠物大小」，四档：迷你 60% / 小 75% / 标准 100% / 大 120%。窗口会跟着立绘一起伸缩，状态条和气泡始终贴在宠物头顶，选择会自动保存。
- **自动更新**：启动时和每 6 小时查一次 GitHub Release；有新版本时任务面板右上角出现琥珀色「可更新 vX」，点一下自动下载安装包（校验 SHA256）并打开 macOS 安装器，装完重新打开鲸鱼娘就是新版。
- **任务看板**：点一下宠物打开「深海任务台」，看每个会话在做什么、跑了多久、什么时候完成、今天花了多少钱。面板按 Provider 聚合，多个代理同时在线时会标出会话属于谁。
- **跳到 DSH 会话**：点任务行会激活 DSH 桌面版，并在它的侧栏里找到对应会话点开（通过 macOS 辅助功能 API）。首次使用需要在「系统设置 → 隐私与安全性 → 辅助功能」里勾选鲸鱼娘；没授权时会退化成「把会话名复制到剪贴板 + 把 DSH 切到前台」。
- **状态立绘**：待命 / 干饭（吃白饭）/ 等你确认 / 出错 / 完成 / 睡觉 / **代理断连**，共 7 种状态。
- **断连提示**：监控中的代理退出或停止更新时，鲸鱼娘会变暗、挂一个红色「!」徽章，头顶状态条和菜单栏显示「DSH 断连」/「Codex 断连」，并弹一次断连气泡；代理重新起来后会自动恢复并弹「重新连上啦」。
- **随 DSH 自动启动**：插件默认在 DSH 启动后自动拉起鲸鱼娘（没运行就启动，隐藏了就显示），不用再单独打开；想关掉可在插件条目配置 `autoStart: false`。
- **干饭中气泡**：有代理干饭时，宠物头顶常驻一个气泡，显示任务名、当前动作（跑命令 / 改代码 / 读文件…）、已跑时长、第几步、后台任务数，以及费用额度（Go 5h / 周 / 月百分比 + 今日 tokens），每秒刷新。
- **多任务轮播**：多个任务同时在干饭时，气泡每 4.5 秒自动轮换一个任务，用交叉淡入淡出 + 轻微上浮过渡；meta 行会显示 `1/2`、`2/2` 和当前 Provider，不会在切换时闪一下或跳字。任务完成 / 出错 / 等你确认的气泡仍然优先，轮播会暂时让位，结束后自动恢复。
- **Codex 监控**：直接读 `~/.codex/sessions/**/rollout-*.jsonl`，显示 thread 在做什么、当前工具、已跑时长、第几步、今日 tokens。**不依赖 cc-switch / 代理软件**——只要 Codex 自己写了本地 rollout，就能监控；用第三方 API 转发时同样适用。
- **OpenCode 监控**：直接读 `~/.local/share/opencode/opencode.db`（SQLite，只读），显示 session 标题 / 工作区、当前工具、已跑时长、第几步、今日 tokens 和会话费用（USD）。同样不依赖 cc-switch。
- **渠道筛选**：任务台顶部有「全部 / DSH / Codex / OpenCode」渠道栏；切换后工作/等待统计、费用/额度、会话列表和「打开目录」都只看当前渠道，点任务行也只跳当前渠道的会话。渠道栏按已注册 Provider 自动生成，后续接 Claude Code 会自动出现。
- **费用 / 额度**：费用读取和展示分成两层。DSH 适配器通过 `CostMeterLedgerReader` 直接读 `dsh-cost-meter` 的 `ledger.json` —— 套餐窗口百分比取自 `planSamples`，今日 tokens 与插件侧栏口径一致（`input + output + cacheRead + cacheWrite + reasoning`），另外保留今日花费（CNY）。Codex 的 rollout 只有 token，没有价格；OpenCode 的 SQLite 有每个 assistant message 的 `cost`（USD），可以显示今日花费。OpenCode Go 套餐还会从 `opencode.ai` 的只读 usage 接口拉 5h / 周 / 月百分比。多个 Provider 的今日 tokens 会自动相加，费用按币种分开展示。
- **拖动走路（带方向）**：按住拖动时切换成三帧走路循环（左脚在前 / 过渡 / 右脚在前）；宠物会朝着你**当前移动的方向**走——往右拖面朝右、往左拖自动镜像面朝左（按每次鼠标移动的平滑速度判断，拖到最左边再往右拖会立刻转身，不是看相对起点的偏移），身体微微朝移动方向倾斜，并且窗口会以 60Hz 平滑追随指针（不是每个鼠标事件跳一次），看起来是「走过去」而不是被瞬移；松手滑到落点后恢复当前任务状态。
  - 丝滑 / 无残影的几个细节：立绘相关图层全部关闭隐式动画（否则换图会自带 0.25s 交叉淡入，就是残影的来源）；换帧只换 `contents`、不重新布局；三帧 0.2s 一帧、浮动 0.3s 与脚步同步；倾斜用独立的 `leanLayer`，不会打断摇摆动画。
- **完成动作（叉腰得意）**：任务跑完时换成两只手叉在腰上、挺胸抬下巴的得意脸，两帧 0.55s 轮换（憋笑 → 闭眼大笑）加一小段星星粒子；原来那张「举手跳」的 `pet_happy` 保留在 Assets 里没再用。
- **干饭循环**：`work` 是三帧循环（夹饭 → 闭眼嚼 → 张嘴再夹），嘴巴、筷子手和尾巴各动一点，0.22s 一帧；三层立绘裁到同一张画布上用饭碗对位，换帧不抖。
- **闲置摸鱼散步**：待命中每隔 9–20 秒掷一次骰子（40% 概率），她会沿着当前高度自己左右走 2–4.6 秒（54 pt/s，三帧走路循环，碰到屏幕边缘自动转身），走完停在原地并记住位置。被她被碰、有任务开始、打开任务面板时都不会散步；右键「空闲时自己散步」可关闭。
- **拎起来 / 摔一跤 / 爬起来**：按住拖动时不再走路——切到**被拎住后颈**的姿势（身体横过来、弓着背、四肢下垂），两帧轮换（垂手 / 挥爪抗议，0.26s 一帧）再叠一层轻微钟摆，地面阴影淡到几乎看不见，往哪边甩就往哪边倾。松手时窗口**就停在松手的位置、不再下落**，只有立绘演一段：下落帧（两帧 0.15s 轮换、先在空中顿一下再快速坠地，共 0.85s）→ 翻肚皮摔懵（压扁 + 抖动，0.75s）→ 坐起来揉头（0.3s）→ 弹一下站稳、恢复当前任务心情。整套约 2s，中途再按住她可以打断、直接重新拎起来，中途再按住她可以打断、直接重新拎起来。右键「放下时摔一跤」可以关掉这段演出。
- **事件提醒**：
  - 有任务需要你确认：琥珀色气泡常驻 + 提示音；
  - 任务完成：开心跳一下 + 气泡 + 音效；
  - 任务失败：惊慌表情 + 抖动 + 气泡。
- **菜单栏小鱼**：带状态色点；菜单里有暂停监控、提示音开关、宠物大小、检查更新、回到右下角、隐藏桌宠、退出。
- **只读本地**：只读取各代理自己的本地日志（DSH 读 `~/.dsh/sessions` 和 `~/.dsh/storages/cost-meter`，Codex 读 `~/.codex/sessions`，OpenCode 读 `~/.local/share/opencode/opencode.db`），不修改任何代理配置；只在检查更新和 OpenCode Go 套餐查询时访问网络。

## 运行

要求 macOS 13+（当前为 Apple Silicon 构建）。

```bash
open build/WhaleGirl.app
# 或者
make run
```

装进 Applications：

```bash
cp -R build/WhaleGirl.app /Applications/
open /Applications/WhaleGirl.app
```

开机自启：**系统设置 → 通用 → 登录项 → +**，选择 `WhaleGirl.app`。

第一次启动它会出现在屏幕右下角（Dock 上方），直接拖动即可换位置；位置、提示音和大小设置会自动保存。

## 操作

| 操作 | 效果 |
| --- | --- |
| 单击宠物 | 打开 / 收起任务面板 |
| 点击头顶气泡 | 收起任务信息，变成「▸ 任务」小条；再点小条展开 |
| 点击「▸ 任务」 | 展开回完整任务气泡 |
| 看头顶气泡 | 干饭中显示任务名 / 动作 / 时长 / 套餐额度 / 今日 tokens；多个任务时每 4.5s 自动轮播；等你确认 / 完成 / 出错时自动切换 |
| 看任务面板用量条 | `Go 5h %`、`Go 周 %`、`Go 月 %`、`今日 tokens` 四个数字；OpenCode Go 套餐会显示自己的 5h / 周 / 月 |
| 点任务面板渠道栏 | 在「全部 / DSH / Codex / OpenCode」之间切换；统计、费用、会话列表和「打开目录」都跟着当前渠道 |
| 拖动宠物 | 被拎起来：悬空站姿 + 钟摆晃动 + 影子消失；往哪边甩就往哪边倾 |
| 松手 | 就放在松手的位置，只演动画：下落 → 翻肚皮摔懵 → 坐起来 → 站稳（窗口不移动） |
| 待命时 | 每隔 9–20 秒有 40% 概率自己左右散步 2–4.6 秒，走到屏幕边缘会转身 |
| 双击宠物 | 咕噜咕噜～随机互动 |
| 右键宠物 | 快捷菜单（任务面板、暂停、提示音、空闲散步、放下时摔一跤、宠物大小、重置位置、退出） |
| 右键宠物 → 宠物大小 | 迷你 60% / 小 75% / 标准 100% / 大 120%，立即生效并记住 |
| 点面板右上角「可更新」 | 自动下载新版 pkg、校验 SHA256，并打开 macOS 安装器 |
| 菜单栏小鱼 / 右键宠物 → 检查更新 | 手动查一次 GitHub Release（没网或限流会提示） |
| 菜单栏小鱼 | 状态摘要、最近任务、暂停监控、提示音、宠物大小、检查更新、重置位置、退出 |
| 点击任务行 | 跳到 DSH 桌面版里对应的会话 |
| 右键任务行 | 跳到 DSH 会话 / 在 Finder 中打开工作区 / 复制会话 ID / 复制日志路径 |
| 右键宠物 → 授权跳转 | 打开辅助功能授权提示和系统设置面板 |

也可以在终端里直接切档（方便脚本 / 快捷指令）：`open bluefish://size/0.75`，`/75` 也认。

## DSH 状态是怎么推断的

DSH 的会话日志是 **多帧 zstd 压缩的 JSONL 事件流**。鲸鱼娘不装插件，只读这份日志：

| 状态 | 依据 |
| --- | --- |
| 干饭中 | 最近有 `turn/start`，其后还没有 `turn/end`，且日志在 4 分钟内仍在更新 |
| 等你确认 | 有 `approval/asked`，且找不到对应的 `approval/decided` |
| 出错 | `turn/end` 的 `reason.kind` 为 `error`（或 `aborted`） |
| 完成 | `turn/end` 的 `reason.kind` 为 `completed`，保持约 2 分钟庆祝状态 |
| 疑似卡住 | 还在 turn 里，但超过 6 分钟没有任何新事件 |
| 睡觉 | 最近一条会话事件超过 20 分钟 |
| 干饭内容 | 最近一次 `tool/call`（跑命令 / 改代码 / 读文件 / 画图 / 派子代理…） |

- **任务时长**从最近一条 `user/message`（对首轮任务则是会话里的首条用户消息）算起，不是单次模型 turn，所以长任务会显示「1h12m」而不是「40s」。
- **今日消耗**来自 `~/.dsh/storages/cost-meter/ledger.json`；如果没装 cost-meter，面板显示 `—`。
- 会话标题来自 `session/title`；工作区路径来自会话头的 `cwd`；已归档会话会按 `workspace.json` 过滤掉。

## Codex 状态是怎么推断的

Codex 每个 thread 是一份 JSONL：`~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl`。适配器只读文件末尾，事件映射如下：

| 状态 | 依据 |
| --- | --- |
| 干饭中 | 最近有 `event_msg.task_started`，其后还没有 `task_complete` / `turn_aborted`，且文件仍在更新 |
| 完成 | `event_msg.task_complete` |
| 失败 | `event_msg.turn_aborted`（`reason` 写入气泡）或 `task_failed` / `stream_error` |
| 当前动作 | `item_completed` 的 `CommandExecution` / `FileChange` / `McpToolCall` / `Extension`，或 `response_item.custom_tool_call` / `function_call` |
| 今日 tokens | `token_usage_record.usage.total_tokens`；如果 thread 是今天创建的，则用 `thread_token_usage.total_tokens` 覆盖，避免只读尾部漏掉当天早期调用 |
| 额度 | `event_msg.token_count.rate_limits`（官方账号可能有；cc-switch / 第三方转发通常为 `null`，这时不显示额度） |

- **不依赖 cc-switch**：cc-switch 只负责把 Codex 的 API 指向别的供应商；Codex 仍然把 rollout 写在 `~/.codex/sessions`，所以直接用 Codex 自己的日志即可。别人没装 cc-switch 也能监控。
- **Codex 没有金额**：rollout 只有 token，没有美元 / 人民币价格；面板显示今日 tokens。若以后想显示金额，可以再加一个可选的 pricing 表，而不是依赖某个代理软件。
- **多 Provider**：Codex、OpenCode 和 DSH 同时在跑时，任务列表按状态排序并标出渠道名，今日 tokens 相加。

## OpenCode 状态是怎么推断的

OpenCode 使用本地 SQLite：`~/.local/share/opencode/opencode.db`。`session` 存标题、cwd、模型、累计 tokens / cost 和时间；`message` 存 user / assistant 消息与 usage；`part` 存 text / tool / step 等片段。适配器只读，不写 WAL。

| 状态 | 依据 |
| --- | --- |
| 干饭中 | 最新 assistant 消息还没有 `time.completed`，或 `finish` 含 `tool-calls`；`session.time_compacting` 非空；tool part 仍是 `running` / `pending` |
| 完成 | 最新 assistant 消息有 `time.completed` 且 `finish` 不是 tool-call |
| 失败 | 最新 assistant 消息带 `error` |
| 等你确认 | `session.permission` 非空 |
| 当前动作 | 最新的 text / tool part；tool 会映射成「跑命令 / 读文件 / 改代码 / 搜代码 / 调工具…」 |
| 今日 tokens / 花费 | session 是今天创建的用累计值；更早的 session 用今天 message 的 usage / cost 求和 |

- **标题**：OpenCode 的 `title` 经常是 `New session - …`，这种会退化成最新用户 prompt。
- **Go 套餐额度**：本地 DB 没有 5h / 周 / 月 meter。适配器会读取 `account_state` / `account` 里的账号和 org，在账号确实有 Go 订阅时请求 `opencode.ai/console/api` 的只读接口：
  - `/orgs/current` → `hasGoSubscription`；
  - `/usage/summary?since=…` → 窗口内 `totalCostMicroCents`。

  5h / 周 / 月的额度按 OpenCode Go 的公开限额计算：Go = $12 / $30 / $60，Go Plus = $48 / $120 / $240。5h 用滚动 5 小时、周用 UTC 周、月用最近 30 天，因此是**近似值**；百分比基于账号整体 usage，而不是只统计本机。
- **不需要 cc-switch**：OpenCode 自己把 session 写进本地 SQLite；cc-switch 只影响 API 供应商，不影响这份数据。

## 实现要点

- **Swift + AppKit**，一个菜单栏 App，不用 Electron / WebView。
- 透明无边框 `NSPanel` + Core Animation 做立绘、气泡、粒子、呼吸浮动；鼠标穿透由定时器 + `ignoresMouseEvents` 控制，只在指针真正落在宠物/气泡上时接收点击。
- **按需解压**：日志 5 MB 的时候整份解压要几十毫秒；这里只读文件末尾 384 KB，从 zstd 帧边界开始解，一次刷新约 1~2 ms。文件没变化就完全跳过。
- **内置 zstd helper**：`scripts/zstd_helper.c` 静态链接 `libzstd.a`，编译成 `WhaleGirl.app/Contents/MacOS/zstd-helper`。运行时不需要 Homebrew zstd。
- **Provider 抽象**：会话扫描、状态推断、应用存活检测、费用读取、会话跳转都收在 `AgentProvider` 协议后面；`AgentMonitor` 只负责定时轮询和汇总 `FleetStatus`，任务面板、气泡和菜单栏不再依赖 DSH 的状态类型。
- **轮播是稳定的**：气泡维护自己的任务 ID 队列，不直接按 `workingSessions` 的实时排序取下一项，所以会话活动时间变化不会导致重复/跳号；旧气泡做快照后与新内容交叉淡入淡出，过渡期间点击穿透。
- 首次启动会全量扫一遍现有会话（约 2~3 秒），之后每次 1.5 秒增量刷新。

## 动作管理器

所有动作集中定义在 `Sources/BlueFish/PetAction.swift` 的一张表里：

| 动作 | 帧 | 帧间隔 | 缩放 | 浮动 | 摇摆 | 徽章 | 粒子 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| idle | pet_idle | — | 1.0 | 5 / 3.0s | 0.014 | — | 慢气泡 |
| work | pet_work / pet_work_b / pet_work_c（嚼饭 3 帧） | 0.22s | 0.85 | 3.5 / 1.45s | 0.020 | — | 快气泡 |
| wait | pet_idle | — | 1.0 | 2.5 / 2.2s | 0.014 | ! | — |
| happy | pet_smug_a / pet_smug_b（叉腰得意 · 炫耀） | 0.55s | 1.0 | 6 / 1.1s | 0.014 | — | 星星 |
| panic | pet_panic | — | 1.0 | 4 / 0.55s | 0.030 | ! | — |
| sleep | pet_idle | — | 1.0 | 7 / 4.4s | 0.012 | — | 慢气泡 + zzz |
| offline | pet_idle | — | 1.0 | 3 / 3.6s | 0.014 | — | — |
| walk | pet_walk_a / b / c（朝右，往左镜像） | 0.2s | 1.0 | 2.2 / 0.3s | 0.02 | — | 慢气泡 |
| walk | pet_walk_a / b / c（朝右，往左镜像） | 0.2s | 1.0 | 2.2 / 0.3s | 0.02 | — | 慢气泡（拖动走路已改为「拎起来」，这条留给闲置散步） |
| held | pet_held_a / pet_held_b（被拎后颈 / 挥爪抗议） | 0.26s | 1.0 | 0 / — | 0 | — | 慢气泡 |
| falling | pet_fall / pet_fall_b | 0.15s | 1.0 | 0 / — | 0 | — | — |
| down | pet_down（翻肚皮摔懵） | — | 1.0 | 0 / — | 0 | — | — |
| getup | pet_getup（坐起来揉头） | — | 1.0 | 0 / — | 0 | — | — |
| held | pet_idle | — | 1.0 | 0 / — | 0 | — | 慢气泡（悬空：钟摆动画在 `bodyLayer` 上） |
| falling | pet_panic | — | 1.0 | 0 / — | 0 | — | — |

- `PetActionManager` 决定当前动作、按 `frameInterval` 切帧，并处理「散步时走路优先、松手恢复当前心情」。
- `PetSpriteView` 里额外有一层 `bodyLayer`（在 sway 层和立绘之间），专门做「被拎起来 / 下落 / 落地」的姿态变换；这段时间 `bodyPhase != .normal`，控制器的 `setMood` 会被暂存到 `deferredMood`，等站稳后再应用，所以任务状态不会在摔倒过程中把表情抢回去。
- `PetSpriteView` 只负责渲染：`applyAction` 配置一次（帧、缩放、浮动、摇摆、徽章、粒子），`applyFrame` 只换图；三帧走路共用同一张对齐画布，所以换帧不位移、不闪。
- 想加新动作：在 `PetAction` 里加一条记录，把对应 PNG 放进 `Assets/`，然后在需要的地方调用 `actionManager.play(...)`（目前入口是 `setMood` / `startWalking`）。

## 多代理监控架构

```text
DSHProvider ────┐
CodexProvider ──┼─ AgentMonitor ── FleetStatus ── StatusCard（渠道筛选）/ 气泡 / 菜单栏
OpenCodeProvider┘                              │
ClaudeProvider（待接）                         └─ UsageReader / OpenCodeQuotaReader
```

- **`AgentProvider`**：一个代理的所有差异都封在这里——日志在哪、怎么判断应用在跑、怎么把事件变成 `AgentSession`、费用从哪来、能不能跳到会话。
- **`AgentMonitor`**：唯一的定时器。它按顺序调用每个 Provider 的 `refresh(now:)`，把结果装进 `FleetStatus`，在主线程回调 UI。
- **`FleetStatus`**：UI 只消费这一层。它会算好 `attentionSessions`、`workingSessions`、`todayTokens`、`costLine`、`mood`、`headline`，并保留每个会话的 `providerID / providerName`。
- **`UsageReader`**：费用/额度的最小接口。DSH 用 `CostMeterLedgerReader` 读 `dsh-cost-meter`；Codex 直接在自己的 rollout 里统计 token；OpenCode 从 SQLite 读 tokens / cost，并用 `OpenCodeQuotaReader` 拉 Go 套餐 meter。只返回 `tokens` 时，面板会自动显示 tokens。
- **`AgentCapabilities`**：声明是否支持 `sessionJump`、`reveal`、`usage` 等。UI 根据能力决定是否显示「跳到会话」「打开目录」，不需要 switch Provider 类型。

### 接入新的代理（以 Claude Code 为例）

Codex 和 OpenCode 都是内置实现，`Sources/BlueFish/CodexProvider.swift` / `OpenCodeProvider.swift` 可以直接当模板看。新增一个代理仍然是三步：

1. 新建 `Sources/BlueFish/ClaudeCodeProvider.swift`，实现 `AgentProvider`：

```swift
final class ClaudeCodeProvider: AgentProvider {
    let id = AgentProviderID.claudeCode
    let displayName = "Claude Code"
    let shortName = "Claude"
    let watchPath: String? = NSHomeDirectory() + "/.claude/projects"
    let capabilities: AgentCapabilities = [.sessions, .usage, .reveal]

    func refresh(now: Date) -> ProviderStatus {
        // 1. 枚举自己的日志文件（建议按 size/mtime 做缓存）
        // 2. 用 LogTail.readJSONLines(...) 只读末尾，映射成 AgentSession
        // 3. 汇总今日 token（UsageTotals），需要额度就填 UsageQuota
        ProviderStatus(
            id: id, name: displayName, shortName: shortName,
            running: true, sessions: sessions,
            usage: ProviderUsage(providerID: id, providerName: shortName,
                                 today: totals, quotas: []),
            watchPath: watchPath, capabilities: capabilities, updatedAt: now
        )
    }
}
```

2. 在 `AgentProvider.swift` 的 `AgentProviderRegistry.makeDefaultProviders()` 里追加一行：

```swift
ClaudeCodeProvider(log: log),
```

渠道筛选栏会自动多出 Claude 的 tab，不需要改任务面板。

3. 不需要改 TaskBoard、气泡、菜单栏或费用条：它们都读 `FleetStatus`。

日志格式参考（本机实测）：Codex 的 `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl` 用 `event_msg` 的 `task_started` / `task_complete` 表示 turn，`token_usage_record` / `token_count` 带 usage；Claude Code 的 `~/.claude/projects/<encoded-cwd>/<uuid>.jsonl` 用 `assistant.message.stop_reason`（`tool_use` / `end_turn`）、`tool_use` / `tool_result` 和 `message.usage` 表示进度。两者都可以直接用 `LogTail.readJSONLines` 尾读。

## 构建

```bash
make build       # 编译并打包 build/WhaleGirl.app
make run         # 构建后启动
make snapshot    # 把 7 个状态 + 任务面板渲染到 snapshots/
make preview     # 生成 README 的 preview.png
make art         # 从 dsh-image-gen/image-b35645c3.png 重新切 Q 版四态立绘
make walk        # 从 dsh-image-gen/image-0b00dab6.png 重新切两帧走路图
make dist        # 打一个 dist/鲸鱼娘.zip
```

构建期需要：

- Xcode Command Line Tools（`swiftc`、`iconutil`、`clang`）；
- Homebrew 的 zstd 静态库：`/opt/homebrew/opt/zstd/lib/libzstd.a`（只用于编译内置 helper，不会成为运行时依赖）。

### 换立绘

四张透明 PNG 放在 `Assets/`：

```text
Assets/pet_idle.png    待命 / 睡觉 / 等待确认
Assets/pet_work.png    干饭（吃白饭）· 帧 1
Assets/pet_work_b.png  干饭 · 帧 2（闭嘴嚼）
Assets/pet_work_c.png  干饭 · 帧 3（张嘴 · 筷子放下）
Assets/pet_smug_a.png   完成 · 叉腰得意
Assets/pet_smug_b.png   完成 · 叉腰大笑
Assets/pet_happy.png    完成（旧版举手跳，已停用）
Assets/pet_panic.png   出错
Assets/pet_walk_a.png  拖动走路 · 朝右 · 右脚在前
Assets/pet_walk_b.png  拖动走路 · 朝右 · 过渡帧
Assets/pet_walk_c.png  拖动走路 · 朝右 · 左脚在前
Assets/pet_held_a.png  被拎起来 · 垂手
Assets/pet_held_b.png  被拎起来 · 挥爪抗议
Assets/pet_fall.png    松开后下落
Assets/pet_down.png    摔在地上 · 翻肚皮
Assets/pet_getup.png   爬起来 · 坐起来揉头
```

- Q 版四态原图切分：`scripts/prepare_sheet.py`，当前切分线 `x=620, y=620`（`make art`）。
- 走路三帧切分：`scripts/prepare_walk.py dsh-image-gen/image-bce7de69.png --splits 486,978`（`make walk`）；三帧是朝右的三分之四侧身，往左走时整体镜像。三帧统一对齐到同一画布（头部中心 + 地平线），所以换帧不会抖。
- 工作姿态比站立姿态容易显大，`Sources/BlueFish/PetAction.swift` 里 work 动作的 `scale` 当前是 `0.85`；玩家可以在「宠物大小」里整体缩放，想改各姿态的相对大小仍改这张动作表。
- 角色设定：Q 版、鲸鳍耳 + 鲸鱼尾、两条细腿；根据用户提供的 DeepSeek-chan 同人图重绘。
- 鲸鳍耳：从太阳穴向外伸出、尖端略向下（约 15–25°），耳面藏青带脊线，下缘一圈浅蓝白波浪鳍膜；鲸鱼尾从裙摆后侧伸出，尾根藏青、尾尖浅蓝；趴着干饭那张尾巴压在腿前面，一只鞋从尾巴后探出来。
- 改立绘时：`scripts/normalize_sprite.py in.png out.png` 负责抠白底 / 清 alpha halo / 裁边（白底走边界 flood fill 并去白边，自带 alpha 的直接清边）；走路帧再走一遍 `scripts/prepare_walk.py` 的 `align()` 对齐到同一画布。当前 7 张原图在 `dsh-image-gen/image-*.png`，被否掉的中间稿在 `dsh-image-gen/drafts/`。

## 目录

```text
Sources/BlueFish/
  main.swift               入口 / --dump / --check-update 诊断
  AppDelegate.swift        启动与快照模式
  UpdateChecker.swift      GitHub Release 检查、下载、SHA256 校验、更新菜单/面板状态
  AgentModels.swift        AgentSession / ProviderStatus / FleetStatus / Usage 统一模型
  AgentProvider.swift      AgentProvider 协议、capabilities、Provider 注册表
  AgentMonitor.swift       定时轮询所有 Provider，汇总成 FleetStatus
  UsageMeter.swift         UsageReader 协议 + dsh-cost-meter ledger 读取器
  LogTail.swift            zstd / JSONL 尾读工具（供所有日志型 Provider 复用）
  DSHProvider.swift        DSH 适配器：会话日志扫描、zstd 尾解压、状态机、跳转
  CodexProvider.swift      Codex 适配器：rollout JSONL 尾读、turn/工具/token 映射
  OpenCodeProvider.swift   OpenCode 适配器：SQLite session/message/part、tokens/cost
  OpenCodeQuota.swift      OpenCode Go 5h / 周 / 月额度读取器
  DSHFocus.swift           DSH 会话跳转（辅助功能）
  PetWindowController.swift 桌宠窗口、气泡、菜单栏联动
  PetAction.swift          动作表 + PetActionManager（所有动作的帧/时长/动画/徽章/粒子）
  PetSize.swift            大小档位、窗口尺寸换算、大小菜单项
  PetView.swift            立绘渲染、气泡、粒子、命中区域
  StatusCard.swift         深海任务台面板
  MenuBar.swift            菜单栏小鱼
  Theme.swift              配色、字体、格式化
  Snapshot.swift           离屏渲染预览
Assets/                    四态立绘 + 图标
scripts/build_app.sh       打包 .app
scripts/zstd_helper.c      内置 zstd 解码器
scripts/prepare_sheet.py   切四态立绘 + 图标
scripts/prepare_walk.py    切两帧走路图
scripts/make_preview.py    README 海报
```

## DSH 插件

想让 DSH 侧边栏出现「鲸鱼娘」按钮、并随 DSH 自动启动：

- 插件仓库：[dsh-plugin-bluefish-pet](https://github.com/davyxiaoxiao/dsh-plugin-bluefish-pet)
- 在 DSH 左侧「插件」页输入 `dsh-bluefish-pet`（npm）安装，重启 DSH；
- 更新插件时先卸载再重装，或使用插件市场的「更新」；App 更新直接覆盖安装新 pkg；
- GitHub 备用：`github:davyxiaoxiao/dsh-plugin-bluefish-pet`；
- 插件会从 `/Applications/WhaleGirl.app` 启动本 App；侧边栏按钮通过 App 内置的 `127.0.0.1:47113` 控制端口切换显示 / 隐藏。

## 调试

```bash
# 打印每个 Provider 的状态、费用来源和推断出来的所有会话
./build/WhaleGirl.app/Contents/MacOS/WhaleGirl --dump

# 用指定的 Codex sessions 目录调试（不影响本机 ~/.codex）
./build/WhaleGirl.app/Contents/MacOS/WhaleGirl --dump-codex /tmp/codex-fixture

# 打印 OpenCode 本地 session / token / cost
./build/WhaleGirl.app/Contents/MacOS/WhaleGirl --dump-opencode

# 单独查一次 OpenCode Go 5h / 周 / 月额度
./build/WhaleGirl.app/Contents/MacOS/WhaleGirl --dump-opencode-quota

# 启动时打开任务面板，并把窗口/点击穿透日志写到 ~/Library/Logs/whalegirl.log
./build/WhaleGirl.app/Contents/MacOS/WhaleGirl --log --open-card

# 用指定大小离屏渲染（0.6 = 迷你，1.2 = 大），检查小/大尺寸下的布局
./build/WhaleGirl.app/Contents/MacOS/WhaleGirl --snapshot /tmp/wg-small --scale 0.6

# 查一次更新（打印当前版本 / 最新 tag / 资产 / SHA256，不开面板）
./build/WhaleGirl.app/Contents/MacOS/WhaleGirl --check-update

# 渲染「可更新」面板（假版本号，方便看 UI）
./build/WhaleGirl.app/Contents/MacOS/WhaleGirl --snapshot /tmp/wg-update --fake-update 9.9.9

# 让运行中的鲸鱼娘立即检查 / 执行更新（脚本、快捷指令）
open bluefish://check-update
open bluefish://update
```

## 隐私

- 平时完全离线；只有两处联网：
  1. 检查更新时请求 GitHub 的公开 Release（API 优先，限流时退回 Release 页面），只带版本号做 User-Agent；
  2. 检测到 OpenCode 账号时，每 2 分钟向 `opencode.ai/console/api` 请求一次只读的订阅/usage 数据：先确认账号是否有 Go 订阅，非 Go 不拉 usage。请求只带本机 `opencode.db` 里已有的账号 Bearer token + org id，不发送会话内容。可用 `defaults write com.daiwei.bluefish BlueFish.openCodeQuotas -bool false` 关闭。
- 更新包只从本仓库的 Release 下载，并用 Release 提供的 SHA256 校验；校验失败不会打开安装器。
- 每个适配器只读自己代理的本地数据。当前内置适配器：
  - DSH：`~/.dsh/sessions`、`~/.dsh/storages/workspace.json`、`~/.dsh/storages/cost-meter/ledger.json`；
  - Codex：`~/.codex/sessions`；
  - OpenCode：`~/.local/share/opencode/opencode.db`。

  不读取 cc-switch 的数据库；以后新增的 Claude 适配器也只读 `~/.claude`。
- 只读取上面列出的本地文件，不修改任何代理的配置，不上传任何东西。
- 自身只在 `~/Library/Preferences/com.daiwei.bluefish.plist` 存位置、提示音开关、宠物大小和上次检查更新的时间。

## 已知取舍

- 状态来自日志推断，不是各家的内部 API；日志被清理、单帧超过 2 MB、或者刚好卡在两个 turn 之间时，会退化成「待命中」而不是「干饭中」。
- 内置 DSH、Codex、OpenCode 适配器；Claude Code 需要按上面的方式新增 Provider。不同版本的日志 / DB schema 可能变化，Provider 内部要能容忍解析失败（返回空数组而不是崩溃）。
- Codex 的 rollout 不含金额和订阅额度；面板只显示 token。cc-switch / 第三方转发下 `rate_limits` 经常是 `null`，不会硬编额度。
- OpenCode Go 的 5h / 周 / 月是近似值：5h 用滚动窗口，月用最近 30 天，且百分比按账号整体 usage 计算。套餐产品默认按 Go 限额；Go Plus 可用 `defaults write com.daiwei.bluefish BlueFish.openCodePlan go-plus` 切换。
- OpenCode 的 SQLite 是 WAL 模式；适配器用只读连接，如果刚好被写锁住，下一次 1.5s 刷新会自动恢复。
- 多来源费用会直接相加：如果同一个套餐同时被 `dsh-cost-meter` 和某个 Provider 统计，任务面板会重复计算。新增 Provider 时只填自己独有的 usage，或者在同一套餐里只保留一个来源。
- 没有系统通知中心推送，只有气泡 + 音效 + 菜单栏色点；如果桌宠被隐藏，瞬间提示会错过。
- 「跳到 DSH 会话」依赖辅助功能权限和 DSH 侧栏里的会话名匹配；侧栏收起、会话名被改过或 DSH 没开时会退化成复制会话名。每次重新构建 App 后 ad-hoc 签名会变，可能需要在辅助功能里重新勾选一次。
- 本地 ad-hoc 签名；拷到另一台 Mac 首次打开可能需要右键 → 打开。
- 自动更新依赖 GitHub Release；安装新版要经过 macOS 安装器（pkg 需要管理员密码），App 不会静默替换自己。如果 GitHub 在共享出口 IP 上触发 API 限流，会退回解析 Release 页面，仍然能检查到新版。
- 角色是 DeepSeek 同人二创，仅作个人桌面装饰使用。

## 后续可以加

- Claude Code Provider（DSH / Codex / OpenCode 已接入，可作为模板）；
- 系统通知 / 任务完成时 Dock 弹跳；
- 多屏幕独立宠物、自动游走；
- 任务面板里的 token / 预算趋势图；
- 一键把 DSH 会话面板叫到前台（需要 DSH 暴露稳定入口）。

---

立绘参考：用户提供的 DeepSeek-chan 同人图；zstd 由 Meta/Facebook 的 zstd 项目提供。
