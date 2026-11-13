# 赫尔墨斯 · 编码规范（各模块约束）

> 与 `docs/STRUCTURE.md`（东西放哪）、`docs/PLAN.md`（做什么）并列，
> 本文回答：**代码怎么写、什么能提交、什么红线不能碰。**
> 规则来源：v0 实测沉淀 + 宪法（AGENTS.md）。冲突时以宪法为准。

## 一、通用（全仓库）

### 文件与编码

1. 源码一律 **UTF-8（无 BOM）**；唯一的例外是 `.ps1`：
   **必须 UTF-8 with BOM**（PowerShell 5.1 对无 BOM 文件按 ANSI 读，中文必变 mojibake）。
2. 行尾：仓库以 `.gitattributes` 为准；新文件默认 LF（.ps1/.cmd 除外，保持 CRLF）。
3. 文件名：Gleam/Erlang 用 `snake_case.gleam/.erl`，Rust 用 `snake_case.rs`，
   文档用大写 kebab（`ARCHITECTURE.md`、`README.en.md`）。
4. 注释写**为什么**（决策、陷阱、边界），不写**是什么**（代码自明）。中文注释 OK。

### 提交纪律

1. Conventional Commits：`feat|fix|docs|test|refactor|chore(scope): 摘要`，中文摘要 OK。
   一次提交只干一件事；代码 + 测试 + 文档同变更同提交。
2. **可以提交**：源码、锁文件（Cargo.lock / package-lock / manifest.toml）、
   配置（nats.conf / tauri.conf / capabilities）、生成产物（gen/schemas 由 .gitignore 排除）。
3. **禁止提交**：
   - 一次性补丁/缝合脚本（修完即弃，如历史里的 `tools/patch_*.py`）；
   - 构建产物（`target/`、`build/`）、运行数据（`infra/natsdata/`、`server.log`）；
   - 机器特定路径（`D:\...`）出现在任何**已跟踪文件**里——工具链路径只能出现在
     本机脚本 fallback 或环境变量；
   - 密钥材料（`.gitignore` 已含 `*.key/*.pem/.env`，新类别先补 ignore 再落盘）。
4. 提交前门禁：`server` → `gleam check && gleam test` 全绿；
   `core`/`storage` → `cargo check && cargo test` 全绿；改动 UI 则构建一次 release。

### 红线（违反 = 打回）

- 跨 VM / 跨进程唯一性场景**禁止 `erlang:unique_integer`**，必须 `hermes_ffi:unique_inbox`
  （NATS subject、request inbox、测试数据目录、持久化 key——全算）。
- 客户端业务逻辑只进 `core/`；视图层（desktop/ios/android）零逻辑。
- server 永不解密；core 的密钥/明文不越过调用边界出现在 pub 签名里。
- 不自研加密协议；加密只走官方 libsignal。

## 二、server（Gleam / Erlang）

### Actor 写法

1. State 是**单一 record**，消息处理后用 `actor.continue(State(..state, ...))` 返回；
   禁止可变引用、禁止 ETS 旁路（状态外置走 store sidecar）。
2. 消息入口一律 `pub fn start(...)` + `supervised(...)`（supervision.worker 包装）；
   对外用 `named_subject` 通信，不用裸 pid。
3. request/reply 用 `process.new_subject()` 临时 subject 即发即收；不要手写 call 超时循环。
4. **给 actor 配自定义 selector 时，默认 subject 必须在 initialiser 里
   `process.select(subject)` 加回来**（已知陷阱：不加 = 业务消息静默丢弃）。
5. spawn：注意 `actor.start` 是 linked spawn；父子都该活 → 父先 `trap_exits(True)`。
   monitor 过的进程要 `demonitor_process`，处理 `'DOWN'` 时对未知 monitor 兜底吞掉。
6. `process.new_name` 只在程序入口调用一次，**绝不进循环**（烧穿原子表）。

### 模块与 FFI 边界

1. 内部模块全部放 `src/hermes/` 下，文档头注明"内部"；`src/hermes.gleam` 只做入口编排。
2. Erlang 代码只允许两个文件：`src/hermes_ffi.erl`（NATS）、`src/hermes_store_ffi.erl`
   （port 驱动）；Gleam 侧用 `hermes/ffi.gleam`、`hermes/store.gleam` 以 `@external` 包装，
   **返回值在包装层归一化成 Gleam 类型**（复杂元组不裸穿）。
3. 协议解析失败（坏 JSON、未知 type）→ 丢弃 + 日志，**不许 crash actor**；
   crash 只留给监督树管的真错误。
4. 增删 Envelope 变体时：`envelope.gleam`（encode/decode）、`proto/hermes/v1/README.md`、
   `core/src/codec.rs` **三处同改**，一处漂移 = 串线 bug。

### 测试

- gleeunit，每个 actor 一个 test 文件（`hermes_test` / `bus_test` / `store_test`）。
- bus 用 fake（Subject 收集 publish），跨测试 subject 名必须带唯一后缀（unique_inbox 类随机）。
- 断言消息序列时注意 actor 的广播顺序（如 Join → Notice → Members），排空再断言下一段。

## 三、core（Rust）

### 结构与错误

1. 子模块按职责切：`transport` / `codec` / `sync` / `idempotency` / `crypto`；
   crate 内不加新"层"。
2. 错误 v0 允许 `String` / 轻量 newtype（`CryptoError(String)`）；分层错误类型等第二轮
   UniFFI 时再做。错误信息要带上下文（who + what），不裸 `.unwrap()` 生产路径。
3. serde 字段名与 `proto/hermes/v1/README.md` **严格对齐**，映射用显式
   `#[serde(rename)]`，禁止依赖默认命名猜字段。

### 并发模型（固定，不自由发挥）

1. WS IO / 重连在 tokio；**crypto 独占 std 线程**（`crypto::spawn`），
   命令走 `std::sync::mpsc`，事件走 `tokio::sync::mpsc`——这是 libsignal
   `async_trait(?Send)` !Send 约束的既定解法，禁止把 store 调用搬进 `tokio::spawn`。
2. 线程内 store 调用用 `now_or_never()` 收敛；挂起（None）按错误处理并上报事件。
3. 随机数固定 rand **0.9** 线：`StdRng::from_os_rng()`（0.8 的 OsRng trait 已劈叉）。
4. 消息事件与命令不共享锁、不用 `Arc<Mutex>` 串业务状态；一切走 channel。

### 边界

- `pub` API（`connect` 等）签名里**不出现** crypto/store 内部类型；
  密钥材料、明文缓冲不出 crate。
- 新增 ServerFrame/ClientFrame 变体 = 同步改 codec 测试 + proto README。

### 测试

- `cargo test --lib` 全绿才提交；crypto 相关测试用独立的临时 keys_dir
  （`std::env::temp_dir()` 下带随机后缀），禁止读写真实 app-data 目录。

## 四、storage（Rust sidecar）

1. **stdout 只输出行协议**（`{packet,4}` + JSON 行）；任何日志/报错 → stderr 或 eprintln。
2. 请求/响应一一对应；响应必含 `ok` 或 `error` 字段，错误不静默、不半响应。
3. key 语义集中常量化（`cursor:<room>:<name>` 等），不散落字符串拼接。
4. 无网络端口；被 kill 由 server 监督重启（port owner 重建），数据靠 fjall 自恢复。

## 五、clients/desktop（Tauri）

1. `main.rs` 只做装配（连接、事件桥、命令注册），不出现协议/业务分支。
2. UI 事件 `emit` / `listen` 命名对称成对，前端 `event.listen` 依赖
   `capabilities/default.json`——新增事件先查权限。
3. 主题：颜色只用 CSS 变量 token（`--panel` / `--accent` 等）；
   暗色改动必须同步亮色（双主题 forever）。
4. 多开走 release 构建（`hermes.cmd client`），**禁止两个 `tauri dev`**（文件锁 os error 5）。

## 六、proto / tools / scripts

- proto：字段**只加不删不改义**（向后兼容）；wire 变更三处同改（见二.4），
  v0 JSON 字段以 `proto/hermes/v1/README.md` 为唯一事实。
- `tools/` 只放**可复用**工具（e2e 冒烟、icon 生成、debug 客户端）；
  一次性脚本用完即删。
- `scripts/` 里 PowerShell：中文必须 BOM；多条 shell 语句拼接长文件用
  Python 脚本做（PS 内联 here-string 转义是已知雷区）。
- 测试/演示数据（房间名、目录）一律带随机后缀，防跨运行串线。
