# ITI — Intent Trajectory Integration

**The real Intent-to-Action end-to-end testing framework.**

ITI is a natural behavioral DSL and runner that follows a behavior from the user's Intent to its Actions, integrations, data effects, observable outcome, and full execution trajectory.

The initial runtime is written for **Zig 0.16** and validates static `.iti` specifications at **comptime**.

## The DSL

```text
AS Human $customer

I OPEN Login
I TYPE $customer.email INTO Email
I TYPE $customer.password INTO Password
I CLICK Login

I HOPE SEE Dashboard
```

Intent-level behavior can use the same language:

```text
AS Human $customer

I OPEN Products
I TYPE "Xiomi cellphone" INTO Search
I CLICK Search

I HOPE SEE "Xiaomi Redmi Note 15"
I WISH buy Product
WITH payment PIX
I HOPE receive PIX
```

The browser path is not the contract unless explicitly asserted. `I HOPE` represents the expected Destination; the real path is observed as the Trajectory.

## Why Trajectory?

ITI uses the vocabulary established by [OpenTrajectory.Digital](https://github.com/suissa/OpenTrajectory.Digital):

```text
Intent
  ↓
Trajectory
  ├─ Track
  │   └─ Expansion
  ├─ Track
  │   └─ Expansion
  └─ ...
  ↓
Destination / I HOPE
```

The first exporter is an ordered NDJSON stream. TUI and Web Dashboard are designed as projections of the same stream, not independent test runners.

## Run

Requires Zig 0.16.

```bash
zig build test
zig build run
```

Run another embedded DSL and profile:

```bash
zig build run -Dspec=examples/purchase.iti -Dprofile=full -Dui=tui
```

Profiles:

```text
minimal
standard
data
performance
full
```

The `full` profile selects:

```text
intent
unit
integration
e2e
semantic

data.write
data.read
data.cache
data.search
data.vector
data.graph
data.events

performance.benchmark
performance.load
performance.stress

trace
discovery.graph
discovery.semantic
```

## Compile-time guarantees

The executable package root is the repository root, so specifications under the project (for example `examples/login.iti`) can be loaded through `@embedFile` and parsed during compilation. Unknown statements produce `@compileError`.

This means a malformed static ITI behavior cannot silently reach the runner.

## Current v0 foundation

Implemented:

- Zig 0.16 build layout.
- `.iti` natural DSL.
- comptime parsing and validation.
- Actor binding with `AS`.
- browser vocabulary: `OPEN`, `TYPE ... INTO`, `CLICK`.
- Intent vocabulary: `WISH`, `WITH`, `HOPE`.
- compile-time test profiles.
- `full` profile covering intent/unit/integration/E2E/data/performance/discovery selection.
- OpenTrajectory-compatible Trajectory / Track / Expansion event model.
- append-only NDJSON output suitable for realtime consumers.\n- terminal projection using the same Trajectory event stream.\n- Web Dashboard shell in `web/index.html`, ready to consume the same events over WebSocket.
- DSL parser tests.

Next runtime adapters are documented in [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md): real Lightpanda CDP execution, WebSocket server, OpenTrajectory exporter, and concrete data-plane probes.


## Lightpanda CDP E2E runtime

When the selected profile includes E2E (`standard` and `full`), ITI connects to the CDP endpoint at `127.0.0.1:9222`. If no server is listening, it starts `lightpanda serve --host 127.0.0.1 --port 9222` and waits for the WebSocket handshake before executing the browser suite.

Install Lightpanda with the [official installer](https://lightpanda.io/docs/open-source/installation/):

```bash
curl -fsSL https://pkg.lightpanda.io/install.sh | bash
export PATH="$HOME/.local/bin:$PATH"
```

Set `ITI_BASE_URL` to resolve relative `I OPEN` targets. Actor values are supplied through environment variables: `$customer.email` resolves to `ITI_CUSTOMER_EMAIL`, `$customer.password` to `ITI_CUSTOMER_PASSWORD`, and dots/hyphens become underscores. Literal values can be quoted in the DSL.

```bash
ITI_BASE_URL=http://127.0.0.1:3000 \
ITI_CUSTOMER_EMAIL=customer@example.com \
ITI_CUSTOMER_PASSWORD=secret \
zig build run -Dprofile=standard -Dui=tui
```

A deterministic local browser smoke test is available:

```bash
ITI_CUSTOMER_EMAIL=smoke@example.com zig build run -Dspec=examples/e2e-smoke.iti -Dprofile=standard -Dui=ndjson
```

## Realtime WebSocket event stream

The same sequenced events emitted by the NDJSON runner and interactive TUI are published to a local WebSocket hub at `ws://127.0.0.1:7331`. The server starts with the ITI process; multiple clients can connect and receive the retained run history followed by live events.

```bash
zig build run -Dui=tui
```

Open `web/index.html` in a browser while the TUI process is running. The page subscribes to the snapshot/replay protocol and renders the event stream; it does not execute tests. The hub retains the latest 2,048 events. Clients that reconnect with a stale cursor receive a fresh snapshot instead of blocking the runner. The server binds to loopback only and does not expose an unauthenticated remote listener.

WebSocket protocol frames carry `protocol: "iti.trajectory"`, `version: 1`, a process `sessionId`, and monotonic sequence numbers. The TUI and browser consume the same Event values from `trajectory.Console`.
