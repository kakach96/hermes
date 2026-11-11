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
