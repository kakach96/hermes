# Project Hermes · Architecture (v0)

> Component structure and runtime data flow of the v0 end-to-end loop.
> Directory contract: `docs/STRUCTURE.md`; roadmap & status: `docs/PLAN.md`.
> 中文：[docs/ARCHITECTURE.md](ARCHITECTURE.md)

## 1. Overview

```
 ┌─────────────────────────────────────────────────────────────────┐
 │                            clients                              │
 │        desktop (Tauri)      ·      ios/android (round 2)        │
 │                pure views — zero business logic                 │
 └───────────────────────────────┬─────────────────────────────────┘
                                 │ Rust API (v0) / UniFFI (round 2)
 ┌───────────────────────────────▼─────────────────────────────────┐
 │                         core (Rust)                             │
 │    transport · codec · sync(cursor) · idempotency(Bloom)         │
 │           crypto — libsignal (X3DH/PQXDH + double ratchet),     │
 │           keys never leave core                                 │
 └──────────────┬───────────────────────────────────┬──────────────┘
                │ WebSocket (JSON, v0)              │
                │ (QUIC + protobuf, round 2)        │
 ┌──────────────▼───────────────────────────────────▼──────────────┐
 │                  server (Gleam on Erlang/OTP)                   │
 │    ws (mist) · session · rooms(dynamic) · room · meta · bus     │
 │        opaque E2E relay — ciphertext only, never plaintext      │
 └───────┬─────────────────────────────────────────┬───────────────┘
         │ NATS protocol                           │ Erlang port (stdio, JSON lines)
 ┌───────▼────────────────────┐        ┌───────────▼─────────────────────┐
 │   NATS JetStream (infra)   │        │  storage sidecar (Rust, fjall)  │
 │   hermes_chat stream:      │        │  device cursors, key registry   │
 │   chat persist + replay    │        │  (supervised, crash-restartable)│
 │   presence: transient subs │        └─────────────────────────────────┘
 └────────────────────────────┘
```

One sentence: **views (Tauri) hold zero logic → all client logic lives in core →
the server only orchestrates sessions/routing/persistence → NATS JetStream owns
durability and replay → the fjall sidecar owns externalized state (cursors).**

## 2. Components

| Component | Language | Owns | Explicitly does not |
| --- | --- | --- | --- |
| `clients/desktop` | Tauri (JS + Rust shell) | rendering, event forwarding | any business/crypto logic |
| `core` | Rust | WS transport, codec, per-device cursor, Bloom idempotency, libsignal crypto | know server internals |
| `server` | Gleam/Erlang | WS access, session actors, room actors, NATS I/O, prekey registry, port driver | decrypt (sees ciphertext only) |
| `storage` | Rust (fjall) | externalized state sidecar: get/put line protocol | expose any network port |
| `infra` | NATS v2.15.3 | JetStream durable stream + transient presence channel | float versions |

## 3. Runtime data flow

### 3.1 Join & live roster

```
client ──join{name, cursor, space?, channel?}──► session
         ├─ name checks: user names are loose; space/channel must be
         │   subject-token safe
         ├─ metadata registration (fjall meta partitions): user_touch /
         │   auto space creation (first joiner = owner) / auto channel
         │   creation / durable membership (members partition)
         ├─ rooms manager: lazily spawn a room actor per <space>.<channel>
         └─ room.Join
              ├─ dedupe + move-to-front
              │  (roster = connection lifetime, never persisted)
              ├─ presence: Notice("xx joined")
              ├─ presence: Members(snapshot)  ← live roster
              └─ reply: current members
```

- Membership equals connection lifetime: server restart / socket drop = left;
  the roster is **never persisted** (identity keys and cursors are).
- Every join/leave broadcasts a `Members` snapshot on the presence channel so
  earlier joiners keep their encryption target set fresh.

### 3.2 Encrypted messages (the only message path; `msg` frames are legacy debug)

```
core:
  plaintext ──► for each peer in roster:
             no session ──► prekey_fetch ──► X3DH/PQXDH session establishment
             double-ratchet encrypt ──► enc{to, body, dedup_id}
server:
  enc ──► room ──► NATS hermes.rooms.<room> (persisted in the hermes_chat stream)
       ──► fanout to all room subscribers (only `to` decrypts; others drop)
storage:
  per-device cursor put_async (fjall sidecar)
```

- The server treats `body` as an opaque string — **no server-side decryption
  path exists by construction**.
- Self-echo: your own messages appear locally, instantly, without the
  encrypt-to-self round trip.

### 3.3 Offline replay (inbox model)

```
reconnect join{cursor} ──► session starts a JetStream ordered consumer
                           at by_start_sequence(cursor+1) ──► replay enc/chat
                           until caught up, then switch to live delivery
```

- Cursor semantics: `cursor` = last fully consumed seq for that device;
  **replay starts at cursor+1** (the `opt_start_seq` value is inclusive).
- One cursor per device; devices never interfere.

### 3.4 Idempotency (business-level backstop for QoS1)

- `dedup_id` is generated by the sender (UUID) and travels with the message.
- core folds duplicates via a Bloom-filter window; QoS2 is never used.

## 4. Crypto flow (pairwise, v0)

| Frame | Direction | Meaning |
| --- | --- | --- |
| `prekey_register{bundle}` | C→S | register local identity/signed-prekey/Kyber-prekey; stored verbatim |
| `prekey_fetch{for}` | C→S | fetch peer bundle; reply `prekey_bundle`, empty = peer not registered |
| `enc{to, body, dedup_id}` | C→S→C | ciphertext envelope, opaque relay |

- Algorithms: official libsignal (Rust), X3DH/PQXDH + double ratchet;
  **rolling our own protocol is forbidden** (constitution).
- Identity keys and session state persist across restarts; at rest they are AES-256-GCM envelopes with the KEK derived from the login password (Argon2id)
  stored as plain JSON (v0 boundary; at-rest encryption is round 2).
- Ratchet session state IS persisted (sessions_<name>.json): ciphertexts from before a restart still decrypt; keys and sessions remain plaintext at rest for now (at-rest encryption is P0-2).
  offline gaps may fall outside the window and fail to decrypt (known v0 edge).

## 5. Key semantic invariants (changes require an ADR)

1. **QoS1 + business-level idempotency**, never QoS2.
2. **Inbox model**: one sequence cursor per device; replay starts at cursor+1.
3. **Roster = connection lifetime**, not persisted; only identity and cursors persist.
4. **Presence uses transient subscriptions**, never enters JetStream.
5. **Retained is for presence only**, never chat history.
6. **server and core never share code dependencies**; they meet only at the proto contract.
7. **Membership (durable) ≠ live roster (transient)**: space members and
   roles live in fjall (members/perms partitions); "who is online now" only
   ever exists in room actor memory.
8. **Space/channel names must be subject-token safe** (`[a-z0-9_-]{1,32}`);
   user names never enter NATS subjects and are validated loosely.

## 6. Known v0 boundaries (round-2 candidates)

At-rest key encryption · session-state persistence · Sender Key group crypto ·
tree fanout (Discord Manifold style) · protobuf + QUIC · UniFFI + iOS/Android ·
ProVerif formal verification.
