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
├── README.md                       # 快速上手
├── docs/
│   ├── PLAN.md                     # 路线图 / Phase 状态 / 踩坑记录
│   ├── STRUCTURE.md                # 本文档
│   ├── ARCHITECTURE.md             # (Phase 2 起) 端到端消息流与加密流说明
│   └── adr/                        # (按需) 0001-xxx.md，重大决策升级为独立 ADR
│
├── proto/                          # [Phase 4] 协议契约，唯一事实来源，无实现代码
│   └── hermes/
│       └── v1/
│           ├── envelope.proto      # 信封：seq / dedup_id / type —— 幂等与游标的落点
│           ├── room.proto          # Join / Msg / Leave
│           └── presence.proto      # 在线状态（retained 语义只在这里）
│
├── server/                         # [Phase 1] 接入层：Erlang/OTP + Gleam（自有 gleam.toml）
│   ├── gleam.toml                  #   name = "hermes"（包名不随目录改，模块前缀稳定）
│   ├── src/
│   │   ├── hermes.gleam            #   入口
│   │   └── hermes/
│   │       ├── sup.gleam           #   监督树组装（从 main 拆出，main 只剩场景编排）
│   │       ├── room.gleam          #   房间 Actor
│   │       ├── session.gleam       #   (Phase 2 起) 会话 Actor：连接态 + 设备游标
│   │       ├── bus.gleam           #   (Phase 2) NATS JetStream 适配
│   │       ├── store.gleam         #   (Phase 3) RocksDB 落库 + UUIDv7 游标拉取
│   │       └── fanout.gleam        #   (Phase 4+) 树状分发（Manifold 思路）
│   └── test/
│
├── core/                           # [Phase 4] Rust 核心：客户端唯一有逻辑的地方
│   ├── Cargo.toml                  #   crate 名 hermes-core；desktop 以 path 依赖接入
│   ├── src/
│   │   ├── lib.rs
│   │   ├── transport/              #   WS 连接、重连、心跳（Phase 6 可升级 QUIC）
│   │   ├── codec/                  #   proto 编解码（prost；生成代码提交入库）
│   │   ├── sync/                   #   收件箱模型：每设备 seq 游标、离线补投
│   │   ├── idempotency/            #   Bloom Filter 去重
│   │   ├── crypto/                 #   (Phase 5) libsignal 封装——密钥只在这里出现
│   │   ├── store/                  #   本地消息库（选型未定，见开放问题）
│   │   └── bindings/               #   UniFFI 导出（Swift/Kotlin 唯一 FFI 面）
│   └── tests/
│
├── clients/                        # [Phase 4] 视图层：零业务逻辑
│   ├── ios/                        #   SwiftUI，只渲染 + 调 core 的 FFI
│   ├── android/                    #   Compose，同上
│   └── desktop/                    #   Tauri 壳
│       ├── src/                    #   壳内前端 UI
│       └── src-tauri/              #   Rust 壳，path 依赖 ../../../core
│
├── infra/                          # [Phase 2] 部署物：与代码同版本演进
│   └── docker-compose.yaml         #   NATS（镜像 tag 锁死），后续加监控
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
                                                    └──► RocksDB
    proto/ ◄──── server 与 core 双方对齐（生成/手工映射）
```

| 组件 | 允许依赖 | 禁止 |
| --- | --- | --- |
| `proto/` | 无 | 出现任何实现代码、任何语言专属内容 |
| `server/` | proto 契约 | 依赖 core / clients；从 core 反向借客户端逻辑 |
| `core/` | proto 契约 | 依赖 server 内部实现；把密钥/log 泄出 FFI 边界 |
| `clients/*/` | core 的 FFI（经 bindings） | 自行实现任何业务/加密逻辑；绕过 core 直连协议 |
| `desktop/src-tauri` | core（path 依赖） | 绕过 core 自己写编解码 |
| `infra/` | — | 漂浮版本号（镜像 tag 必须锁死） |

补充规则：

- `server/` 与 `core/` 之间**永远不发生代码依赖**，它们只在 proto 契约上会师。
- `core` 对外只暴露 `bindings/` 一层 FFI；`crypto/` 与 `store/` 不出现在 FFI 签名里，
  密钥与明文不越过这条线（Phase 5 的硬边界，Phase 4 建骨架时就按此设计签名）。
- Gleam 的 `src/` 下模块自动成为包公共 API，所以 server 内部模块一律放 `src/hermes/`
  下并用文档头注明"内部"， Gleam 目前没有私有模块，靠约定 + 测试兜底。

## 四、分语言要点与坑（提前记录）

- **server（Gleam）**：Gleam 要求 `src/`、`test/` 相对 `gleam.toml` 定位，
  因此 server 必须自带完整 gleam 项目结构；Phase 3 引入 erlang-rocksdb（NIF）时
  **需要 rebar3**，Windows 上大概率还要 MSVC 构建工具链 + CMake——届时补装，
  这是 Phase 3 的第一个环境坑。
- **core（Rust）**：crate 内子模块按"职责"切，不按"层"切；UniFFI 导出类型
  全部放 `bindings/`，避免 prost 类型直接泄漏进 FFI。
- **desktop（Tauri）**：src-tauri 是独立 cargo 项目，用 `path = "../../../core"`
  接入；是否在仓库根统一 Cargo workspace（core + src-tauri 共享 target/）留作
  开放问题，不影响边界。
- **proto**：core 侧用 prost 生成（成熟）；server 侧 Gleam 生态没有成熟的
  protobuf 生成器，候选方案：protoc 的 Erlang 插件 + Gleam `@external` 桥接，
  或先手写编解码。**这是 Phase 4 的选型题，现在不锁答案**。

## 五、目录随 Phase 增长表

| Phase | 新增/触达目录 |
| --- | --- |
| 1（现在） | `server/`（暂存仓库根，见迁移清单）、`docs/` |
| 2 | `infra/`、`server/src/hermes/{session,bus}.gleam`、`docs/ARCHITECTURE.md` |
| 3 | `server/src/hermes/store.gleam`（+ rebar3 工具链） |
| 4 | `proto/`、`core/`、`clients/{ios,android,desktop}`、`tools/codegen` |
| 5 | `core/src/crypto` |
| 6 | `tools/proverif`、`core/src/transport`（QUIC） |

## 六、Phase 1 现状与迁移清单（Phase 2 开工第 0 步执行）

Phase 1 骨架当前平铺在仓库根（Gleam 项目的默认形态）。为不干扰 Phase 1 的
首次本机验证，**验证通过之前保持现状**；进入 Phase 2 时执行：

1. `mkdir server infra tools`
2. 移动 `gleam.toml`、`src/`、`test/` → `server/`（`gleam.toml` 内容不动，包名保持 hermes）
3. 同步更新：README、AGENTS.md 的"常用命令"改为 `cd server && gleam run`
4. 本文档勾掉迁移项；`PLAN.md` Phase 2 勾掉步骤 0

## 七、开放问题（不锁答案，按 Phase 解决）

| 问题 | 决定时点 |
| --- | --- |
| core 本地消息库选型（SQLite / 轻量 KV / 平台方案） | Phase 4，取决于多端查询需求 |
| server 端 protobuf 代码生成方案 | Phase 4 |
| 根级 Cargo workspace 是否统一 core + src-tauri | Phase 4 |
| 房间/会话状态的 supervisor 重启恢复策略（外置到 NATS 还是 store） | Phase 2 |
