# infra

本机运行时依赖。v0 不起 Docker（守护进程未运行），全部用官方单二进制。

## NATS

- 版本锁死：**v2.15.3**（windows-amd64，官方 zip 解包，LICENSE 在案）
- 升级方式：从 <https://github.com/nats-io/nats-server/releases> 下载新版本覆盖
  `nats-server.exe`，并同步修改本文与 `nats.conf` 注释

启动（仓库根执行）：

```sh
infra\nats-server.exe -c infra\nats.conf
```

- 客户端口：4222（server 与 core 都连它）
- JetStream：文件存储，落 `infra/natsdata/`（可随时删掉重来）
- 验证：看到 `Listening for client connections on: 0.0.0.0:4222` 与
  `Starting JetStream` 即就绪

> 注意：`natsdata/` 是运行数据，已 gitignore，别提交。

## Linux / Docker 部署

Windows 开发用仓库内的 `nats-server.exe`（tag 锁 v2.15.3）；Linux 部署
**不提交平台二进制**，改用官方镜像、同样以 tag 锁版本：

```sh
# 仓库根：构建 + 起栈（NATS + server + 存储 sidecar 全容器化）
docker compose up --build -d
docker compose logs -f hermes     # 观察
docker compose down              # 停（数据在 named volumes：nats-data / hermes-storage）
```

- 镜像：`Dockerfile`（多阶段：rust sidecar → gleam erlang-shipment →
  `erlang:29-slim` 运行时，非 root）
- NATS：`nats:2.15.3-alpine` + `infra/nats.docker.conf`（store_dir 指向
  容器卷 `/data`）
- server 的平台相关参数全部走环境变量（compose 里注入）：
  `HERMES_NATS_HOST` / `HERMES_NATS_PORT` / `HERMES_STORAGE_EXE` /
  `HERMES_DATA_DIR`
- 本机有 rust 镜像缓存时，compose 的 `build.args.RUST_IMAGE` 可指向本地
  tag 免拉取（默认 `rust:1-slim`）
