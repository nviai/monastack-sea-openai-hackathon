# Architecture and repository layout

This is the target layout, not an instruction to create empty directories or force a separate crate for every concept. Start with the pieces Stage 1 uses. Favor clear ownership and working integration over scaffolding.

```text
app/                             Flutter application, initially macOS
  lib/app/                       bootstrap, router, composition
  lib/shared/                    shared design system and utilities
  lib/platform/                  OS integration and bridge lifecycle
  lib/features/
    identity/
    organization/
    office/{world,rooms,presence,communication,avatars}/
    agents/
  assets/office/{maps,tiles,objects,avatars,audio}/
  test/ integration_test/ macos/
core/                            Rust workspace
  crates/
    foundation/                  shared IDs, errors and ports
    identity/ organization/      actors, membership and policies
    office-map/ office-rooms/    map rules, geometry, room policies
    presence/ communication/     domain and use cases
    storage/ sync/               local persistence, outbox, sync protocol
    ffi/                         Flutter bridge and generated bindings
    process-host/                core host used by process node as needed
backend/
  sync-node/                     sync, storage and backup
  process-node/                  core host and optional workers
  media/                         media/signaling configuration/adapters
  contracts/                     versioned network contracts
  deploy/                        local and node deployment profiles
data/seed/nviai/                 declarative seed; no credentials
docs/                            architecture, ADRs, protocols and runbooks
tools/                           developer tools
```

Inside each app feature, use `presentation`, `application`, `data`, and `domain` where they have a real role. Presentation holds screens, widgets and Riverpod providers; application coordinates UI use cases; data holds bridge and platform adapters; domain holds UI-facing contracts, not a duplicate of authoritative Rust business rules. Shared libraries must not import feature internals. Features expose deliberate public APIs. Use Riverpod for lifecycle, dependency injection, async/loading/errors and UI state; do not broadcast every animation frame to the entire Flutter UI.

Rust handles reusable domain rules, application use cases, validation, local storage and sync state. Keep domain code independent of Flutter, transport and databases through explicit boundaries. Flutter/Flame owns rendering, interaction and platform APIs. A versioned typed Flutter/Rust bridge must support asynchronous work, explicit errors, disposal and recovery after a missed event. Evaluate flutter_rust_bridge with a real macOS build, pin compatible tools, and keep generated code reproducible. Avoid blocking the UI thread.

Sync, identity/policy authority, realtime presence and media are separate capabilities, even if colocated. Process node and app reuse the same core; process node must not implement a conflicting second copy of business rules. Each backend capability should itself be structured around features and expose versioned contracts.
