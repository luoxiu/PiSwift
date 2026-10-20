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
- 同一条命令再以 `PI_DURABLE_DOCUMENT_RETENTION_MS=0` 跑一遍，两遍都要过（对应上游 `npm test` 的第二遍，`f44707e7f` 起）：
  `PI_DURABLE_DOCUMENT_RETENTION_MS=0 swift test --filter 'PiSwiftDurableTests|PiSwiftChordTests|PiSwiftAgentTests' --skip SessionSetterSettlementTests`。
  这个变量替换所有没有自己设 retention 的 Session 的默认值，每个没被观察的文档用完就从缓存里清掉。

## 上游 durable 提交台账（`v1.1.0..73f8de80b`）

状态：`待移植` / `已移植 <fork sha>` / `不跟` / `挂起`。

| 上游 | 日期 | 标题 | 决定 | 状态 |
| --- | --- | --- | --- | --- |
| `75a99721d` | 2026-10-07 | Add [Unreleased] section for next cycle | 不跟：只加 CHANGELOG 段落 | 不跟 |
| `eba849739` | 2026-10-09 | feat(durable): nested tool calls, structured output, callers; storage errors end the Session | 跟。偏差：Swift 的 listener、`onReport`、`now()` 都不能抛错也不返回 Promise，所以没有 `safeReport`/`safeNow`/`contained`，7 个只测 JS 行为（Promise 拒绝、跨 realm、thenable、不可格式化的值、抛错的时钟）的用例不移植；`ToolHookCall` 用 `@dynamicMemberLookup` 包 `ToolCall`；工具事件的调用字段收进 `DurableToolEventCall`；`StorageRequestError` 包住内置后端的 `DurableStorageError`；并发 `executeTool` 的默认 key 按开始执行的顺序编号，不保证调用顺序，重跑要靠显式 key；结构化输出用 PiSwiftAI 的 `JSONSchemaValidator`，报错文字与 TypeBox 不同；Node 基准脚本不移植 | 已移植 5bbd2d1 |
| `42a3497d0` | 2026-10-09 | feat(durable): read returns images, optional Photon image processor | 跟。偏差：Photon（WASM）换成 ImageIO / Core Graphics 的 `createImageIOImages()`，放在 PiSwiftDurable 里、不另设入口（系统框架没有要延迟加载的东西），只在能 import ImageIO 的平台存在；步骤照上游（按 EXIF 方向逐像素转正、BMP 转 PNG、按上限缩放、JPEG 源先试 JPEG、质量 80/70/55/40、每轮缩到 3/4），但 JPEG 质量换成 ImageIO 的 0–1 刻度、插值用 Core Graphics 高质量插值而非 Lanczos3，重编码的字节和 Photon 不同；`ImageProcessor` 是协议，字节用 `[UInt8]`；base64 用 Foundation，上游手写的 `toBase64` 和它的测试不移植；`images-wasm-module` 测试（WebAssembly 模块初始化）没有对应；`read-differential.json` 不重生成：400 个种子没有一个是图片，新参考实现只改了图片分支，测试里加断言兜住；诊断里的坐标倍数按 JS `toFixed(2)` 处理恰好一半（`%.2f` 会把 2.125 写成 2.12），多一个用例 | 已移植 ef1370c |
| `cb4375493` | 2026-10-10 | fix(durable): scheduler no longer visits every live task on each pass | 跟。偏差：索引是调度器 `State` 的字段，所有遍历都在它的 Mutex 里跑（Swift 调度器多线程读写），方法放在 `TaskSchedulerOwnership.swift`；Swift 的 Set 没有插入顺序，所以列表、预约、标记、finalize 每轮和 conversation abort 都按任务变成 live 的先后（`State.order`）排序，和移植前一致；上游此前已有、Swift 原先没移植的 `#failFastChecks` 一并补上（原来每轮扫全部 live 任务）。测试：深链端到端用 2,000 而非 20,000，因为 `MemoryStorage` 状态索引的删除和事务对每个 terminal 任务调一次的 `createdTaskIDs()` 都是线性的，20,000 要在调度器之外跑几分钟，另加一条只测索引的 20,000 深链用例；遍历开销用内部探针 `State.walked` 计数，不改写 Set 迭代，1000 兄弟用例的上限从每个 20 收紧到 2 并在计数前等调度器静止（哈希顺序下逐个复查只多走约 n·ln n）；上游 Node SQLite 换成 `SqliteStorage`；Node 基准脚本不移植 | 已移植 9315a5d |
| `4ac0bd8c7` | 2026-10-10 | feat(durable): one document per nested call; TaskRuntime.ownedTasks() | 跟。偏差：`NestedCallDoc` 的 seed 上游是 `null`，Swift 用 `JSONValue`，取成员时传 `.null`；`ownedTasks()` 在 Session line 上、调度器 Mutex 里读 `State.below[.task(id)]`，按 id 排序，`TaskRecord` 是值类型，返回的本来就是副本；每个 attempt 只提交一次的 `pi.tool.madeNestedCalls` memo 由 `NestedAdmissions` 里的一个 `HarnessPromise` 合并，失败就清掉，下一次调用重试；文档改成按 key 寻址后 `5bbd2d1` 的默认 key 偏差不变：key 仍在 `executeTool` 开始执行时取号，文档地址、调用 ID 和回读用同一个 key，所以「一个调用一个文档」用例里两个并发调用的 `document.create` 先后不固定，按 key 排序后比较；`ownedTasks` 的两个用例放在同文件新的 `TaskRuntimeOwnedTasksTests` suite 里，探针等门时被 abort 返回 nil 而不是抛错，重开后换一组新的门代替 `gates.clear()`；结构化输出用例照上游改用 `subscribeCommits`，不再包存储；Node 基准 `nested-images-bench.ts` 没有移植过，不跟 | 已移植 22d948b |
| `b9f2b3e82` | 2026-10-10 | docs(durable): read only through tx inside a commit callback | 跟。偏差：上游 `Harness extends Session`，`Harness.commit` 继承 `Session.commit` 的注释；Swift 的 `Harness.commit` 是单独的方法，同一句注释也写上；spec 的 pitfalls 一节 Swift 没有对应文件，写进 README 的 Concepts | 已移植 edb0924 |
| `e37cdc420` | 2026-10-10 | fix(durable): drop redundant nested-call parent check; test ownedTasks() with a held child | 跟。无偏差 | 已移植 aad965b |
| `ea448f454` | 2026-10-10 | fix(durable): bound the scheduler's ownership indexes by live work | 跟。偏差：`State` 够不到 Session line，所以 `dropIfUnneeded` 只把节点放进 `dropQueue`，清理任务由 `TaskScheduler.scheduleSweep()` 排：`loadChain` 每次 `settle`、`setEdge` 之后调它，`observe` 在锁里最后直接 `sweep()`；清理任务是 `Task` 里的一次 `readOnLine`，Task 开跑时才排上 line，可能比上游晚几个操作才清，只会晚放，不会在操作中途清；`cb4375493` 那条「先计入 `knownChildren` 再由 `forget` 减掉」的偏差随这套计数删掉；没有 `SCHEDULER_INDEX_SIZES` 和 `indexSizes`，测试 `@testable` 直接读 `harness.tasks.state`。测试：20,000 深链端到端用 2,000，理由同 `cb4375493`，那边只测索引的 20,000 用例改成先清掉、再照 chain load 装回、再清掉；「被忘掉的会话里再来工作」用例上游比的是拿 handle 之前的读次数，`harness.conversation()` 和 `getTask` 轮询自己就读，断言恒真，Swift 只数拿到 handle 之后到链装好之间的 task 读；「abort-mark 的 owner 下新建工作」用例给 `keep` 加 `slowAbort`，否则多线程下 P 可能在 `late` 建出来之前就结束，`late` 照常跑、等门挂住；「intent 后出现、两层之下排队」用例在排队后多断言一次没有扫 queued submissions（上游只有注释；实测去掉 intent 门时，移植过来的「没有取消时不扫」用例照样通过，因为它的 root 链已经装好，只有这一条拦得住）；「链装载期间 scope 保持 busy」用例轮询被拦的那次读，不直接 await，行为回退时测试失败而不是挂死；Node SQLite 换成 `SqliteStorage`；`scheduler-memory-bench.ts` 不移植 | 已移植 3d3b4d1 |
| `f44707e7f` | 2026-10-11 | feat(durable): bound the Session's document cache by use (documentRetentionMs) | 跟。偏差：`documentRetentionMs` 的类型是 `DocumentRetention`（`.milliseconds(Int64)`，整数字面量即毫秒；`.forever` 对应 `Infinity`），名字和单位跟同结构里的 `contextRetentionMs` 一样；类型里放不下 NaN 和非数字，「不是非负毫秒数按默认」只剩负数；默认值由库在第一次用时读 `PI_DURABLE_DOCUMENT_RETENTION_MS`，因为 Swift Testing 没有在所有 suite 之前跑的 setup 文件，没有 `setDefaultDocumentRetention`；测试在一个进程里并行跑，改进程级默认值会波及别的用例，所以上游两条先把默认值钉回十分钟的用例改成：非法值那条按本轮默认值断言（另直接测 `documentRetention()`），Harness 设置那条先把设置设成十分钟；清理计时器是真实时间 sleep 的 Task（上游也是用注入的 `now` 算延迟、`setTimeout` 计时），不走 Harness 的 `DurableClock`，否则几十个用例里 `TestClock.pendingSleeperCount` 会多一个；Task 不会让进程活着，「计时器不能 unref 时只在 commit 时清」做成 internal 的 `SessionTimer`，返回 nil 即谢绝，只有测试用（上游测试替换 `globalThis.setTimeout`）；`.forever` 不起计时器（上游会起一个 24.8 天后空转的）；缓存、idle 顺序、pin 计数和待定清理都在 Session `State` 的 Mutex 里，`currentSnapshot` 在 line 外命中缓存时在同一把锁里记使用，时钟和设置是宿主代码，拿锁之前读；Swift 字典没有插入顺序，idle 顺序用 `IdleDocuments`（按使用排队，跳过被同一文档后来的使用替换掉的记录，过多时压缩）；清理 job 在排的那一刻同步 `line.reserve()`，再起 Task 等票，对应上游 `queueMicrotask` 后立即 enqueue（不这样，「驱逐后再迁移」用例里测试的 settleLine 会排到清理前面）；`commitWith` 在被拒、settle 失败、没有写入、正常发布之后都清，storage commit 和 adopt 失败两条出口不清，那时 Session 已失败、close 清空缓存，和上游一致；pin 放在 `attachObservation`，unpin 进 `ObservationSubscriptions`，detach、close、attach 失败都会 release，收到 retire 的那次提交里立刻 unpin。测试：抛错时钟那条不移植；NaN 和字符串不移植；无 `unref` 的 `setTimeout` 改成计时器谢绝；「同样的事件」那条每步等到自己的 update 事件再走下一步，不睡 5 ms；retire 那条多断言 `attached == 0`（不加时去掉 retire 时的 unpin 照样通过）；另加两条：回调抛错的 commit 之后清，line 外 snapshot 和 commit、驱逐并发时值不乱；`openTestSession` 钉十分钟，`settingsResolveOverDefaults` 加 `documentRetentionMs`；Node 基准 `session-document-cache-bench.ts`、`heap-retained.ts` 和 `scheduler-memory-bench.ts` 的改动不移植 | 已移植 e4cc1e4 |
| `cdaf6c227` | 2026-10-11 | feat(durable): prepare images in a worker thread in /images/node | 不跟：Node 图片 worker 线程（/images/node），Swift 侧没有对应运行时 | 不跟 |
| `e6b9a6af5` | 2026-10-11 | feat(durable): inputs placed as application entries, display-only writes appended at once | 跟。偏差：`InputEntry` 是只有 `kind`、`data` 的结构体，解码只取这两个成员，上游在入队和放置时用 `pickInputEntry` 挑字段，Swift 的类型本身就挑了；`.input` 的 `entry:` 放在 `whenBusy` 和 `requestId` 之间；kind 不合法抛 `SessionError.message`（文字同上游 `TypeError`），kind 不是字符串的情况 Swift 类型里放不下；`InboxItem` 上 input 的 entry 另设 `inputEntry` 属性（JSON 里仍是 `entry` 键，和 TS 的 JSONL / SQLite 互通，`data: null` 和没有 data 分开），`entry` 仍只表示 write 的 `EntryDraft`，所以 `InboxItem` 改成手写 `encode`；`appendInput` 收已经拼好的 user message，空闲路径照旧用 `encodeMessages`、boundary 照旧用存着的 content 拼 JSON；判断 display-only 用 `!= nil`（空数组也算出现）；查排队 reset 要解码一遍 inbox 快照；spec 的改动写进 README 的 Extensions and Tools 和 `Conversation.submit`、`admitSubmission` 的注释，`generation.ts` prepare 那段注释 Swift 没有对应。测试：上游「untyped caller 的 entry 只取 kind 和 data」改成往存储里的 inbox 项塞多余成员（另一种实现写的那种），看放置时只取 kind 和 data；kind 为 123 那条不移植；`types.test.ts` 是编译期断言，不移植；Node SQLite 换成 `SqliteStorage`，`setup.now` 换成 `HarnessOptions.now`；`harness-inbox` 和 `harness-ownership` 里改成 `queuedNote` 的写入在 Swift 对应的 `HarnessInboxTests`、`HarnessInboxIntegrationTests`、`HarnessH6FacadeTests` 同样改；上游示例 20 没改（注释还说 write 会排队），Swift 示例测试按新行为断言：note 立即 done、inbox 只剩两项、transcript 里 `app.note` 在第一个回答之前；另加三条：inbox 项和 TS 同形的 JSON 编解码、`model: []` / `edits: []` 的写入照样排队、README 新代码块；coding-agent experimental 的改动不跟 | 已移植 c051248 |
| `15e7bdc14` | 2026-10-11 | fix(coding-agent,durable): omit thinking from compaction summaries | 跟。durable 无偏差；coding-agent 部分 Swift 有对应（`PiSwiftCodingAgent` 的 `serializeConversation`，`Core/Compaction/Utils.swift`），一并去掉 thinking。偏差：那个函数是原作者更早的移植，工具参数写成 `key=value` 而不是上游的 JSON 值，工具结果按 10000 字符截断、没有上游的截断提示，这些不在这次范围里，所以上游「should omit thinking」用例按 Swift 的参数格式断言 `read(path=a.ts)`；上游 `compaction-serialization.test.ts` 另外三条依赖 2000 字符截断，Swift 没有移植过，这次也不移植；`docs/compaction.md` Swift 没有对应 | 待移植 |
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

（还没有。不属于上游移植的改动记在这里，并说明能否回提给原作者。）

待办（追平上游之后再看，先确认上游 TS 有没有同样的问题）：

- `MemoryStorage` 的状态索引删除是线性的；事务对每个 terminal 任务都重算一次 `createdTaskIDs()`。
  2 万个任务的深链要跑几分钟，会掩盖 `cb4375493` 的调度器优化（见那一行的偏差）。Bear Days 用 `SqliteStorage`，影响小。
- Swift 的 reconcile 每一轮都调 `loadQueuedScopes()`：扫一遍 queued submissions，再装每个排队输入所在会话的链。上游只在
  `cascadePending` 时做（`#loadScopes(cascade)`），原作者 H5 起就是这样。`ea448f454` 之后，这类会话下面没有 live 工作时，
  链每轮装完就被清掉，下一轮再从存储读。排队输入通常意味着会话在跑，影响小；对齐上游要先确认没有 Swift 测试依赖每轮都撤回。
- `LocalExecutionShellTests`「ends after the idle grace period and does not call back after return」偶发失败（原作者的代码里就有，
  移植前的基线跑里出现过）：全量并行跑时偶尔断言 `descendant-done` 文件不存在失败，单独跑稳定通过。和时间有关，Bear Days 不用 shell。
- `SessionSetterSettlementTests` 在线程池里用信号量堵线程，并行跑会把 10 核机器的线程池占满卡死；串行全过。可回提给原作者。
