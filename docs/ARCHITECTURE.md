# ITI architecture

ITI treats an Intent trajectory as the unit of end-to-end testing.

## Pipeline

```text
.iti source
   │
   ├─ @embedFile
   │
   ├─ comptime parser + validation
   │
   ▼
Behavior specification
   │
   ├─ Actor / AS
   ├─ browser steps
   ├─ Intent / I WISH
   ├─ Destination / I HOPE
   └─ context / WITH
   │
   ▼
Runner
   │
   ├─ intent
   ├─ unit
   ├─ integration
   ├─ e2e / Lightpanda
   ├─ semantic
   ├─ data.*
   ├─ performance.*
   └─ discovery.*
   │
   │
   ├─ E2E browser executor
   │    └─ Lightpanda CDP (127.0.0.1:9222)
   │
   ▼
OpenTrajectory-compatible event vocabulary
   │
   ├─ Trajectory
   ├─ Track
   ├─ Expansion
   ├─ Destination
   └─ causal relations
   │
   ├───────────────┬──────────────┬───────────────┐
   ▼               ▼              ▼               ▼
NDJSON           TUI          WebSocket     OpenTrajectory.Digital
                                 │
                                 ▼
                           Web dashboard
```

## Compile-time DSL

The initial implementation deliberately parses static `.iti` files at compile time. Unknown statements call `@compileError`, making the behavior specification part of the program's compile-time contract.

```bash
zig build run -Dspec=../examples/login.iti -Dprofile=full
```

The path is relative to `src/main.zig` because it is consumed by `@embedFile`.

## DSL v0

```text
AS Human $customer

I OPEN Login
I TYPE $customer.email INTO Email
I TYPE $customer.password INTO Password
I CLICK Login

I HOPE SEE Dashboard
```

Supported statements:

- `AS <ActorType> <id>`
- `I OPEN <target>`
- `I TYPE <value> INTO <target>`
- `I CLICK <target>`
- `I WISH <intent expression>`
- `WITH <context>`
- `I HOPE <destination>`
- `I HOPE SEE <target>`

## Profiles

`minimal`, `standard`, `data`, `performance`, and `full` are compile-time profiles.

The `full` profile selects Intent resolution, unit tests for Actions, integration tests, E2E, semantic tests, all configured data-plane probes, benchmark/load/stress, trace, and discovery probes.

## Realtime protocol

The core emits an append-only event stream. The first exporter is NDJSON because the exact same stream can feed a terminal UI or a WebSocket server without coupling either UI to the runner.

Event families:

```text
run_started
trajectory_started
track_started
expansion
assertion_passed
assertion_failed
data_probe
benchmark_sample
track_finished
trajectory_finished
run_finished
```

## Implemented runtime adapters

- Lightpanda CDP executor on `127.0.0.1:9222`, auto-starting the local server when no endpoint is listening.
- Browser actions for navigation, actor-bound input, selector/text click, and visible-destination assertions.
- Per-step benchmark samples emitted into the same event stream.
- WebSocket hub and TUI projections sharing the same sequenced events.
- OpenTrajectory.Digital v1 exporter with Trajectory, Track, Expansion, Destination, semantic identity, and causal relations.

## Next adapters

1. Data-plane adapters discovered from project configuration rather than hard-coded database vendors.
2. Browser extraction and semantic evidence via Lightpanda's `LP.getMarkdown` and accessibility-tree APIs.
3. Selector fallback and retry policies for dynamic pages.
4. Isolated per-run browser contexts and managed server lifecycle.
5. OpenTelemetry correlation and trace export.
