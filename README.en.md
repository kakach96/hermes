# Project Hermes (赫尔墨斯)

A self-indulgent IM system where every technology choice benchmarks against
industry state-of-the-art: product-grade mindset, toy-grade scale.
The full chain "access → bus → storage → crypto → client", as a deep dive into
the BEAM actor model and high-performance Rust.

[中文](README.md) | [English](README.en.md)

## Architecture at a glance

```
Tauri clients ×N ──WebSocket──► server (Gleam/OTP) ──► NATS JetStream (persist + cursor replay)
                    │                │
                    │                └─Erlang port─► storage (fjall sidecar: cursors/registry)
                    │
core (Rust) = the only place client logic lives (transport/cursor/Bloom dedup/libsignal crypto)
```

- Full component diagram & data flows: [`docs/ARCHITECTURE.en.md`](docs/ARCHITECTURE.en.md)
- Roadmap & current status: [`docs/PLAN.md`](docs/PLAN.md) (Chinese; the v0
  end-to-end loop is complete — M1–M6 all green)

## Running

Prerequisites: Erlang/OTP 26+, Gleam 1.x, Rust stable (msvc), Node 18+
(client build only), rebar3. (The launcher probes and prepends a local
toolchain when it is not on the system PATH.)

```sh
# One-command lifecycle (port probing, skip-if-running; processes are detached)
scripts\hermes.cmd up        # NATS + build storage sidecar + server
scripts\hermes.cmd client    # open one client window (repeat to open more)
scripts\hermes.cmd status    # ports & processes
scripts\hermes.cmd down      # stop server + NATS

# Manual equivalent (see scripts\hermes.ps1 for details)
infra\nats-server.exe -c infra\nats.conf
cd server && gleam run       # ws://127.0.0.1:8080/ws
node tools\e2e_ws.mjs        # bare-WS two-client smoke test
```

libsignal is a path dependency (official Rust implementation, shallow-cloned
into `vendor/` at the repo root, not committed):

```sh
git clone --depth 1 https://github.com/signalapp/libsignal vendor/libsignal
```

Tests:

```sh
cd server && gleam test      # server behavior tests
cd core && cargo test        # core unit tests (incl. crypto session round-trip)
```

> ⚠ For multi-window development, never run two `npm run tauri dev`:
> dev rebuilds and overwrites `target\debug\*.exe`, which the first instance
> holds a lock on (os error 5). Build release once, then multi-open the exe
> (that is exactly what the `client` subcommand does).

## Docs

| File | Content |
| --- | --- |
| `AGENTS.md` | project constitution: stack, invariants, working rules, pitfall memo (Chinese) |
| `docs/PLAN.md` | roadmap, milestone status, ADR digest, pitfall log (Chinese, single source of truth) |
| `docs/STRUCTURE.md` | directory contract & dependency boundaries (Chinese) |
| `docs/ARCHITECTURE.en.md` | components, runtime data flow, crypto flow ([中文](docs/ARCHITECTURE.md)) |
| `docs/CONVENTIONS.md` | per-module coding standards, commit discipline, red lines (Chinese) |
| `proto/hermes/v1/README.md` | v0 wire format (JSON frame contract, Chinese) |
