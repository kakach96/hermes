# 赫尔墨斯 server 镜像 —— Linux 部署形态。
#
# 产物：Erlang shipment（BEAM 字节码）+ Rust 存储 sidecar，同容器内运行
#（server 经 Erlang port 拉起 sidecar，宪法边界不变）。
#
# 版本对齐：gleam 1.19.2 官方镜像内置 OTP 29（与本机开发一致）；
# 运行时镜像必须 >= 构建时 OTP 大版本（BEAM 字节码不向后兼容）。
# NATS 不在本文件里——docker-compose.yml 用官方镜像（tag 锁 2.15.3），
# 替代仓库里 Windows 平台专用的 infra/nats-server.exe。

# ---------- ① 存储 sidecar（Rust） ----------
# RUST_IMAGE 是参数：默认官方 tag；本机已有缓存的 rust 镜像时用
# docker-compose.yml 的 build.args 覆盖（如 rust:1.95-bookworm），免拉取。
# 注意：最终运行时镜像与这里必须同 libc 系（bookworm = Debian 12 glibc）。
ARG RUST_IMAGE=rust:1-slim
FROM ${RUST_IMAGE} AS sidecar
WORKDIR /build
# 先拷清单再拷源码：依赖层缓存
COPY storage/Cargo.toml storage/Cargo.lock ./
RUN mkdir src && echo "fn main() {}" > src/main.rs && cargo build --release && rm -rf src
COPY storage/src ./src
RUN touch src/main.rs && cargo build --release

# ---------- ② server（Gleam → erlang-shipment） ----------
FROM ghcr.io/gleam-lang/gleam:v1.19.2-erlang AS build
WORKDIR /build
COPY server/ .
RUN gleam export erlang-shipment

# ---------- ③ 运行时（只带 BEAM + 两个产物） ----------
FROM erlang:29-slim AS runtime
WORKDIR /hermes

# 非 root 运行；数据目录可写
RUN useradd --system --no-create-home --uid 10001 hermes

COPY --from=build /build/build/erlang-shipment ./
COPY --from=sidecar /build/target/release/hermes-storage /usr/local/bin/hermes-storage

# 部署覆盖（compose 里按需改）：sidecar 无 .exe 后缀，NATS 主机名是服务名
ENV HERMES_STORAGE_EXE=/usr/local/bin/hermes-storage \
    HERMES_DATA_DIR=/data/storage \
    HERMES_NATS_HOST=nats \
    HERMES_NATS_PORT=4222

RUN mkdir -p /data/storage && chown -R hermes /hermes /data
USER hermes

EXPOSE 8080
# shipment 的 entrypoint：exec 形式因 SPDX 头会 ENOEXEC，走 shell 形式
CMD ["/bin/sh", "./entrypoint.sh", "run"]
