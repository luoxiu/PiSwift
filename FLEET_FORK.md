# FLEET_FORK

`luoxiu/PiSwift` 是 `xibbon/PiSwift` 的 fork，供 `luoxiu/fleet-apps`（Bear Days 的 Agent Chat）使用。
目标是**忠实上游**：继续继承 `earendil-works/pi` 的改动，结构、命名、存储格式都跟上游走。

## 约定

- `upstream` remote 指向 `xibbon/PiSwift`。原作者有新提交就合进来；能回提的改动做成给他的 PR。
- 原作者移植停在上游 `v1.1.0`（`abe508e1b`，durable 部分）。这个 fork 按上游 TS 提交的顺序继续移植，
  每个上游提交对应这里的一个提交，说明以 `durable: port upstream <短 sha> <原标题>` 开头。
- 范围沿用原作者的口径（`Sources/PiSwiftDurable/README.md`「Swift Differences and Scope」）：库、执行环境、内置工具；
  不含 CLI / TUI / Windows。只对 Node 或 Cloudflare 有意义的提交不跟，原因写在下表。
- 每步之后跑 `swift test --filter 'PiSwiftDurableTests|PiSwiftChordTests|PiSwiftAgentTests' --skip SessionSetterSettlementTests`。
  `SessionSetterSettlementTests` 并行跑会把线程池堵满（测试在线程池里用信号量阻塞线程），串行单独跑；修好后去掉这个 skip。

## 上游 durable 提交台账（`v1.1.0..73f8de80b`）

状态：`待移植` / `已移植 <fork sha>` / `不跟` / `挂起`。

| 上游 | 日期 | 标题 | 决定 | 状态 |
| --- | --- | --- | --- | --- |
| `75a99721d` | 2026-10-07 | Add [Unreleased] section for next cycle | 不跟：只加 CHANGELOG 段落 | 不跟 |
| `eba849739` | 2026-10-09 | feat(durable): nested tool calls, structured output, callers; storage errors end the Session | 跟。偏差：Swift 的 listener、`onReport`、`now()` 都不能抛错也不返回 Promise，所以没有 `safeReport`/`safeNow`/`contained`，7 个只测 JS 行为（Promise 拒绝、跨 realm、thenable、不可格式化的值、抛错的时钟）的用例不移植；`ToolHookCall` 用 `@dynamicMemberLookup` 包 `ToolCall`；工具事件的调用字段收进 `DurableToolEventCall`；`StorageRequestError` 包住内置后端的 `DurableStorageError`；并发 `executeTool` 的默认 key 按开始执行的顺序编号，不保证调用顺序，重跑要靠显式 key；结构化输出用 PiSwiftAI 的 `JSONSchemaValidator`，报错文字与 TypeBox 不同；Node 基准脚本不移植 | 已移植 |
| `42a3497d0` | 2026-10-09 | feat(durable): read returns images, optional Photon image processor | 跟 | 待移植 |
| `cb4375493` | 2026-10-10 | fix(durable): scheduler no longer visits every live task on each pass | 跟 | 待移植 |
| `4ac0bd8c7` | 2026-10-10 | feat(durable): one document per nested call; TaskRuntime.ownedTasks() | 跟 | 待移植 |
| `b9f2b3e82` | 2026-10-10 | docs(durable): read only through tx inside a commit callback | 跟 | 待移植 |
| `e37cdc420` | 2026-10-10 | fix(durable): drop redundant nested-call parent check; test ownedTasks() with a held child | 跟 | 待移植 |
| `ea448f454` | 2026-10-10 | fix(durable): bound the scheduler's ownership indexes by live work | 跟 | 待移植 |
| `f44707e7f` | 2026-10-11 | feat(durable): bound the Session's document cache by use (documentRetentionMs) | 跟 | 待移植 |
| `cdaf6c227` | 2026-10-11 | feat(durable): prepare images in a worker thread in /images/node | 不跟：Node 图片 worker 线程（/images/node），Swift 侧没有对应运行时 | 不跟 |
| `e6b9a6af5` | 2026-10-11 | feat(durable): inputs placed as application entries, display-only writes appended at once | 跟 | 待移植 |
| `15e7bdc14` | 2026-10-11 | fix(coding-agent,durable): omit thinking from compaction summaries | 跟 | 待移植 |
| `89e5c2c07` | 2026-10-11 | fix(durable): fail a run whose blocking compaction failed; keep compaction failures visible | 跟 | 待移植 |
| `d77d2752e` | 2026-10-11 | feat(durable): a schema tool's error result without structuredOutput gives programs its output | 跟 | 待移植 |
| `091bcc099` | 2026-10-11 | fix(chord): append to arrays without walking or copying them twice | 跟 | 待移植 |
| `cd8bdf751` | 2026-10-11 | fix(durable): allow image conversion tests more time on CI | 不跟：CI 超时 | 不跟 |
| `7b597d148` | 2026-10-11 | feat(durable): durable code mode (@earendil-works/pi-durable/codemode) | 挂起：Code mode：上游用 QuickJS-WASI，Swift 侧要换成 JavaScriptCore；Bear Days 不用，先挂起 | 挂起 |
| `127b77121` | 2026-10-11 | feat(durable): code mode result lists the script's tool calls | 挂起：Code mode，同上 | 挂起 |
| `04566631c` | 2026-10-11 | fix(durable): closing the code mode sandbox does not decide the script's outcome | 挂起：Code mode，同上 | 挂起 |
| `8bb180bec` | 2026-10-12 | feat(durable): code mode listing, tool search, output, models.*, grammar; tool error rule | 挂起：Code mode 相关（列表、tool search 输出、models.*、语法）：tool search 与工具错误规则部分跟，其余同上 | 挂起 |
| `c661bc574` | 2026-10-12 | fix(durable): drop shared MCP types from the codemode section | 挂起：Code mode，同上 | 挂起 |
| `f11e50f72` | 2026-10-12 | fix(coding-agent): make codemode output joining linear | 挂起：coding-agent 的 codemode 输出，同上 | 挂起 |
| `77332f7a3` | 2026-10-12 | feat(durable): deferred tools and the tool_search extension | 跟 | 待移植 |
| `eb2fce43d` | 2026-10-12 | fix(durable): reject waits that close a wait cycle | 跟 | 待移植 |
| `2ee5c1e56` | 2026-10-12 | docs(durable): drop the Chord facet usage guide and its test | 跟 | 待移植 |
| `0104fef1e` | 2026-10-12 | feat(chord): replace the facet and service runtime with the chord2 host runtime | 跟 | 待移植 |
| `6db4070f1` | 2026-10-12 | docs: describe only the current Chord, Durable, and coding-agent code | 跟 | 待移植 |
| `abfe62928` | 2026-10-12 | feat(durable): optional ExecutionEnv.listFiles for tree listings | 跟 | 待移植 |
| `55df12bf6` | 2026-10-12 | docs(durable,env): changelog entries for listFiles | 跟 | 待移植 |
| `06a466935` | 2026-10-13 | Release v1.2.0 | 不跟：npm 发版号；Swift 侧版本随移植里程碑在 README 记 | 不跟 |
| `d54794918` | 2026-10-13 | Add [Unreleased] section for next cycle | 不跟：只加 CHANGELOG 段落 | 不跟 |
| `f13c00fb3` | 2026-10-13 | fix: pin internal dependencies to exact versions | 不跟：npm 内部依赖钉版本 | 不跟 |
| `b04299717` | 2026-10-14 | fix(durable): encode base64 with btoa, without retaining concatenation trees | 跟 | 待移植 |
| `5713c9507` | 2026-10-14 | fix(durable): lead with the system baseline after a compaction that keeps assistant messages | 跟 | 待移植 |
| `4a5d37291` | 2026-10-15 | feat(chord,durable): move OutputBuffer and Progress to @earendil-works/chord/output | 跟 | 待移植 |
| `f7e3cb543` | 2026-10-15 | feat(durable): support namespaced SQLite storage (#10937) | 跟 | 待移植 |
| `71023aec1` | 2026-10-15 | Release v1.3.0 | 不跟：npm 发版号；同上 | 不跟 |
| `ae7b16d43` | 2026-10-15 | Add [Unreleased] section for next cycle | 不跟：只加 CHANGELOG 段落 | 不跟 |
| `6085986e4` | 2026-10-16 | fix(durable): type ToolControl.terminate as boolean | 跟 | 待移植 |
| `c4cf7957b` | 2026-10-16 | feat(durable): per-model compaction settings via compaction.modelOverrides | 跟 | 待移植 |
| `790271cd0` | 2026-10-16 | fix(durable): restore ToolControl.terminate changes dropped by c4cf7957b | 跟 | 待移植 |
| `7ec1f648e` | 2026-10-16 | feat(durable): accept functions for HarnessOptions.models and settings | 跟 | 待移植 |
| `2331785c3` | 2026-10-16 | fix(durable): run the Codex prompt-cache e2e test on gpt-6.1-sol | 不跟：TS 端到端测试换模型名 | 不跟 |
| `c268154ca` | 2026-10-17 | feat(chord): move Durable's SQLite drivers into chord/sqlite | 跟 | 待移植 |
| `f75b3240a` | 2026-10-17 | feat(durable): durable sleeping state replaces runtime.sleep | 跟 | 待移植 |
| `ea7c64843` | 2026-10-17 | feat(durable): workerd tests for Durable Object hosting | 不跟：workerd / Cloudflare Durable Object 托管测试 | 不跟 |
| `de47e488f` | 2026-10-17 | docs(durable): changelog for sleeping tasks, timers, and wakeups | 跟 | 待移植 |
| `26b5535a5` | 2026-10-17 | docs(durable): clarify the SQLite schema migration in the changelog | 跟 | 待移植 |
| `ec1be23eb` | 2026-10-17 | fix(durable): review fixes for sleeping tasks and host timers | 跟 | 待移植 |
| `00bf7193d` | 2026-10-17 | fix(durable): arm before resume in the Durable Object example; timer wording | 不跟：Durable Object 示例；只移植其中与 Swift 相关的计时用词（如有） | 不跟 |
| `e17e2e105` | 2026-10-17 | fix(durable): release the second slow call when the first finished, not after 200 polls | 跟 | 待移植 |
| `a30c2a81d` | 2026-10-18 | feat(durable): crash-loop guard, report sources, inbox after failed runs, blocked tasks in the task graph | 跟 | 待移植 |
| `440a5fcdb` | 2026-10-18 | fix(durable): review fixes for the crash-loop guard, reports, and blocked tasks | 跟 | 待移植 |
| `5ba1cbaf3` | 2026-10-18 | fix(durable): close keeps admitted aborts, reports name the extension that ran, review nits | 跟 | 待移植 |
| `91b33cab3` | 2026-10-18 | feat(durable): ReportInfo says what happened, with typed reasons | 跟 | 待移植 |
| `48909d987` | 2026-10-18 | feat: telemetry propagation, span links and metrics; telemetry member in chord/context | 跟 | 待移植 |
| `2ec55d808` | 2026-10-19 | feat: Durable and pi-ai telemetry; Context.telemetry is always a span | 跟 | 待移植 |
| `5c1736f82` | 2026-10-19 | feat: checkpointWhen is required on Durable document definitions | 跟 | 待移植 |
| `61060ddf8` | 2026-09-11 | fix(coding-agent): resolve Windows shells from installation directories | 不跟：Windows shell，PiSwift 原本就不在范围内（README「Swift Differences and Scope」） | 不跟 |

## fork 自己的改动

（暂无。不属于上游移植的改动记在这里，并说明能否回提给原作者。）
