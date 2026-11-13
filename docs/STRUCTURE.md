# 赫尔墨斯 · 目录结构与依赖边界

> 本文档是目录结构的**契约**：新增代码该放哪、谁能依赖谁，以这里为准。
> 与 `docs/PLAN.md` 的关系：PLAN 管"做什么、做没做"，本文管"东西放哪、边界在哪"。

## 一、五条组织原则

1. **目录即依赖边界**：跨目录的引用只允许走依赖关系（path 依赖 / FFI / 消息协议），
   不允许靠相对路径偷文件。每个目录有且只有一个包管理器。
2. **契约先行**：`proto/` 是唯一的协议事实来源，server 和 core 都从它生成/对齐代码。
   改协议 = 改 proto = 两侧同步重生成，不允许某侧"先改了再说"。
3. **逻辑唯一**：客户端的一切业务逻辑（连接、游标、幂等、加密）只存在于 `core/`，
   iOS/Android/Tauri 视图层零逻辑，只渲染 + 调 FFI。这样多端永远不产生行为分叉。
4. **生成代码提交入库**：自嗨项目没有 CI 门禁，生成产物（prost 等）直接提交，
   但生成目录固定、并在文件头标注"DO NOT EDIT"，重生成由 `tools/codegen` 完成。
5. **每 Phase 只长出它需要的目录**：目录树按 Phase 渐进出现（见第五节），
   现在不预建空目录。

## 二、目标目录树

```
hermes/                             # 仓库根 = monorepo 根
├── AGENTS.md                       # 项目宪法：规则与索引，不放实现细节
├── README.md                       # 快速上手（中文）
├── README.en.md                    # 快速上手（English，与 README.md 同步维护）
├── docs/
│   ├── PLAN.md                     # 路线图 / 里程碑状态 / 踩坑记录
│   ├── STRUCTURE.md                # 本文档
│   ├── CONVENTIONS.md              # 各模块编码规范、提交纪律、红线清单
│   ├── ARCHITECTURE.md             # 端到端组件图、运行时数据流、加密流（中文）
│   ├── ARCHITECTURE.en.md          # 同上（English），与中文版同步维护
│   └── adr/                        # (按需) 0001-xxx.md，重大决策升级为独立 ADR
│
├── proto/                          # [M5] 协议契约，唯一事实来源，无实现代码
│   └── hermes/
│       └── v1/
│           ├── README.md           #   v0 线格式：JSON，与 proto 字段一一映射
│           ├── envelope.proto      # 信封：seq / dedup_id / type —— 幂等与游标的落点
│           ├── room.proto          # Join / Msg / Leave
│           └── presence.proto      # 在线状态（retained 语义只在这里）
│
├── server/                         # [M1 迁入 / M3 扩展] 接入层：Erlang/OTP + Gleam（自有 gleam.toml）
│   ├── gleam.toml                  #   name = "hermes"（包名不随目录改，模块前缀稳定）
│   ├── src/
│   │   ├── hermes.gleam            #   入口
│   │   ├── hermes_ffi.erl          #   [M3] 最小 NATS 客户端 FFI（gen_tcp）
│   │   └── hermes/
│   │       ├── sup.gleam           #   监督树组装（从 main 拆出，main 只剩场景编排）
│   │       ├── room.gleam          #   房间 Actor
│   │       ├── session.gleam       #   [M3] 会话 Actor：WS 连接态 + 设备游标
│   │       ├── bus.gleam           #   [M3] NATS JetStream 适配
│   │       ├── store.gleam         #   [M4] hermes-store 的 Erlang port 驱动
│   │       ├── ws.gleam            #   [M3] mist WebSocket 监听
│   │       └── fanout.gleam        #   (第二轮) 树状分发（Manifold 思路）
│   └── test/
│
├── core/                           # [M5] Rust 核心：客户端唯一有逻辑的地方
│   ├── Cargo.toml                  #   crate 名 hermes-core；desktop 以 path 依赖接入
│   ├── src/
│   │   ├── lib.rs
│   │   ├── transport/              #   WS 连接、重连、心跳（第二轮可升级 QUIC）
│   │   ├── codec/                  #   信封编解码（v0 JSON，映射见 proto/hermes/v1/README）
│   │   ├── sync/                   #   收件箱模型：每设备 seq 游标、离线补投
│   │   ├── idempotency/            #   Bloom Filter 去重
│   │   ├── crypto/                 #   [M6] libsignal 封装——密钥只在这里出现
│   │   ├── store/                  #   本地消息库（选型未定，见开放问题）
│   │   └── bindings/               #   (第二轮) UniFFI 导出（iOS/Android 才需要）
│   └── tests/
│
├── storage/                        # [M4] fjall 存储引擎 sidecar（Rust crate hermes-store）
│   ├── Cargo.toml                  #   被server以Erlang port驱动，stdio 行协议（JSON），无网络端口
│   └── src/
│       ├── main.rs                 #   行协议循环：get/put/scan → stdout
│       └── engine.rs               #   fjall 封装：key 空间、compaction 参数
│
├── clients/                        # [M5] 视图层：零业务逻辑
│   ├── ios/                        #   (第二轮) SwiftUI，只渲染 + 调 core 的 FFI
│   ├── android/                    #   (第二轮) Compose，同上
│   └── desktop/                    #   [M5] Tauri 壳
│       ├── src/                    #   壳内前端 UI
│       └── src-tauri/              #   Rust 壳，path 依赖 ../../../core
│
├── infra/                          # [M2] 部署物：与代码同版本演进
│   ├── nats-server.exe             #   官方单二进制（tag 锁死），本机起 NATS 用
│   └── nats.conf                   #   JetStream file storage 配置
│
├── scripts/                        # [冲刺] 一键起停：hermes.cmd up|client|down|status
│   └── hermes.ps1                  #   端口探测防重复拉起；进程经 WMI 脱离父进程
│
└── tools/
    ├── codegen/                    # [Phase 4] proto → prost（server 端方案待定）
    ├── bench/                      # [Phase 4+] 压测：模拟 N 客户端打 server
    └── proverif/                   # [Phase 6] 协议 SPDL 模型
```

## 三、依赖方向（唯一允许的箭头）

```
clients/ios ──FFI──┐
clients/android ─FFI┤
clients/desktop ──path──► core ──WS/QUIC──► server ──► NATS JetStream
                                                      └──► storage（fjall sidecar，Erlang port 驱动）
    proto/ ◄──── server 与 core 双方对齐（生成/手工映射）
```

| 组件 | 允许依赖 | 禁止 |
| --- | --- | --- |
| `proto/` | 无 | 出现任何实现代码、任何语言专属内容 |
| `server/` | proto 契约 | 依赖 core / clients；从 core 反向借客户端逻辑 |
| `core/` | proto 契约 | 依赖 server 内部实现；把密钥/log 泄出 FFI 边界 |
| `storage/`（Rust crate hermes-store） | 独立进程，被 server 以 Erlang port 驱动 | 崩溃可被 server 监督重启；不直接暴露网络端口 |
| `clients/*/` | core 的 FFI（经 bindings） | 自行实现任何业务/加密逻辑；绕过 core 直连协议 |
| `desktop/src-tauri` | core（path 依赖） | 绕过 core 自己写编解码；v0 无 UniFFI，直接 Rust 依赖 |
| `infra/` | — | 漂浮版本号（镜像 tag 必须锁死） |

补充规则：

- `server/` 与 `core/` 之间**永远不发生代码依赖**，它们只在 proto 契约上会师。
- `core` 对外只暴露一层调用边界（v0：src-tauri 直接 Rust 依赖；第二轮 iOS/Android 时
  换成 `bindings/` UniFFI）；`crypto/` 与 `store/` 不出现在调用边界签名里，
  密钥与明文不越过这条线（M6 起的硬边界，M5 建骨架时就按此设计签名）。
- `server` 与 `storage` 之间只走 **Erlang port 的 stdio 行协议**（JSON 行），
  不开网络端口；hermes-store 必须能在被 kill 后由 server 拉起（port + 监督）。
- Gleam 的 `src/` 下模块自动成为包公共 API，所以 server 内部模块一律放 `src/hermes/`
  下并用文档头注明"内部"， Gleam 目前没有私有模块，靠约定 + 测试兜底。

## 四、分语言要点与坑（提前记录）

- **server（Gleam）**：Gleam 要求 `src/`、`test/` 相对 `gleam.toml` 定位，
  因此 server 必须自带完整 gleam 项目结构；Erlang FFI（NATS 客户端）放在
  `src/hermes_ffi.erl`，与 Gleam 模块同名约定：`hermes/ffi.gleam` 用
  `@external` 绑定。
- **core / storage（Rust）**：crate 内子模块按"职责"切，不按"层"切；
  两个 crate 独立 Cargo 项目（是否合并 workspace 见开放问题）。
  本机工具链：rustc 1.97 msvc（无 cmake —— 这正是弃 erlang-rocksdb 选 fjall 的原因）。
- **desktop（Tauri）**：src-tauri 是独立 cargo 项目，用 `path = "../../../core"`
  接入；需要 node + npm（已具备：node 24 / npm 12）。
- **proto**：v0 线格式用 **JSON**（字段名与 proto 一一映射，见
  `proto/hermes/v1/README.md`）；第二轮再上 prost/protobuf 生成，
  届时 core 侧成熟、server 侧仍是选型题。

## 五、目录随里程碑增长表

| 里程碑 | 新增/触达目录 |
| --- | --- |
| M1（现在） | `server/`（迁入）、`infra/`、`storage/`、`core/`、`clients/desktop/`、`proto/`、`tools/` 空壳 |
| M2 | `infra/nats-server.exe` + `nats.conf` |
| M3 | `server/src/hermes/{session,bus,ws}.gleam`、`hermes_ffi.erl`、`docs/ARCHITECTURE.md` |
| M4 | `storage/src/`（fjall 引擎 + port 行协议）、`server/src/hermes/store.gleam` |
| M5 | `core/src/{transport,codec,sync,idempotency}`、`clients/desktop/`（Tauri） |
| M6 | `core/src/crypto`（libsignal） |
| 第二轮 | 树状 fanout、QUIC、UniFFI、iOS/Android、ProVerif（`tools/proverif`）、RocksDB（如需） |

## 六、迁移记录（M1，2026-11-11 已执行）

Phase 1 骨架原平铺在仓库根，M1 执行如下迁移：

1. `mkdir server infra tools storage core clients proto`
2. 移动 `gleam.toml`、`src/`、`test/`、`manifest.toml` → `server/`（包名保持 hermes）
3. README、AGENTS.md 的"常用命令"改为 `cd server && gleam run`

## 七、开放问题（不锁答案，按里程碑解决）

| 问题 | 决定时点 |
| --- | --- |
| core 本地消息库选型（SQLite / 轻量 KV / 平台方案） | M5，取决于多端查询需求 |
| 根级 Cargo workspace 是否统一 core + storage + src-tauri | M5 |
| server 端 protobuf 代码生成方案（第二轮） | 第二轮 |
| 房间/会话状态的 supervisor 重启恢复策略（外置到 NATS 还是 store） | M3/M4 实测后定 |
