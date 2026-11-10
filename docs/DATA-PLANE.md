# DataPlane adapter contract

The DataPlane layer is deliberately provider-neutral. The DSL and runner address capabilities (`read`, `write`, `cache`, `search`, `vector`, `graph`, and `events`); concrete providers implement the `Adapter` callback contract in `src/data_plane.zig`.

## Contract

An adapter declares:

- a stable, non-empty `id`;
- a `CapabilitySet` describing the operations it can perform;
- an opaque provider-owned context pointer;
- a probe callback receiving allocator, `std.Io`, requested capability, and `ProbeContext`.

`ProbeContext` carries correlation, causation, Actor type, Subject ID, Intent ID, Behavior ID, and Action ID. Adapters receive these values as runtime context and must not put credentials into the result detail or emitted events.

## Registry behavior

- duplicate and empty IDs are rejected;
- lookup is deterministic and case-sensitive;
- probing an unknown adapter returns `AdapterNotFound`;
- probing an unsupported capability returns `CapabilityUnsupported`;
- `probeAll` invokes only adapters declaring the capability;
- one adapter failure becomes a failed `ProbeOutcome` and does not prevent other adapters from running;
- elapsed time is measured by the registry and returned as `duration_ms`.

`MemoryAdapter` is a deterministic test fixture, not a production database provider.

## Follow-up

Configuration parsing, driver factories, environment-variable resolution, and wiring results into `data_probe` / `benchmark_sample` events are tracked in [issue #16](https://github.com/suissa/ITI.Intent-Trajectory-Integration/issues/16).