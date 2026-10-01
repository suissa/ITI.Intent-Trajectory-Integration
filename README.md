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
zig build run -Dspec=../examples/purchase.iti -Dprofile=full -Dui=tui
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

The specification is loaded through `@embedFile` and parsed during compilation. Unknown statements produce `@compileError`.

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
