# ADR 0003: Generated asynchronous Flutter ↔ Rust bridge

Status: accepted.

## Context

The prototype called the Rust core through three hand-written C functions (`monastack_policy_v1`, `monastack_path_v1`, `monastack_outbox_v1`) that exchanged JSON strings. Path and policy calls were synchronous on the UI isolate, each call re-sent the full seed, errors were untyped strings, and the outbox needed a manual `Isolate.run` per call. The architecture reference asks for a versioned, typed, nonblocking, generated bridge.

## Decision

Use `flutter_rust_bridge` pinned to **2.13.0** on both sides (`core/Cargo.toml`: `=2.13.0`; `app/pubspec.yaml`: `2.13.0`; codegen 2.13.0).

- `core/src/api/` is the only bridge surface. It adapts domain modules and owns no policy.
- `OfficeCore` is an opaque Rust object created once from the seed and map assets. Loading validates both documents (including that every map room exists in the seed). Dart owns the handle; `officeCoreProvider` disposes it with the provider.
- `find_path` and the outbox functions are asynchronous: they run on the bridge's Rust worker pool and return `Future`s, so the UI isolate never blocks on SQLite or pathfinding. `may_enter`, `room_at` and `bridge_version` are synchronous because they are constant-time lookups.
- Errors are a typed `CoreError { kind, detail }` exception. `kind` distinguishes invalid seed, invalid map, inaccessible destination and outbox failure; outbox `detail` keeps the stable codes the Dart outbox already used (`queue_full`, `not_pending`, …). A struct with a plain enum avoids requiring `freezed`/`build_runner`.
- `bridge_version()` is checked after loading; a mismatched library is unloaded and the app treats the core as unavailable (movement and preview room entry are denied).
- The library is still built by `app/macos/scripts/bundle_core.sh` and loaded from the app bundle (`ExternalLibrary.open(nativeLibraryPath())`), so no cargokit plugin was added. The C ABI functions were removed.

There are no Rust→Dart event streams yet. Presence and chat state come from node polling, which already recovers after missed updates; when a stream is added it must be recoverable by re-reading a snapshot.

## Regenerating

```sh
cd app
flutter_rust_bridge_codegen generate   # reads flutter_rust_bridge.yaml
```

Generated files: `core/src/frb_generated.rs` and `app/lib/platform/bridge/`. They are committed; regenerate after changing `core/src/api/` and commit the result.

## Evidence

- `cargo test --manifest-path core/Cargo.toml`: API tests for seed policy, routing with seed and server room lists, walls, unknown actors and invalid documents.
- `flutter test test/bridge_test.dart`: real calls through the generated binding, including typed errors and an outbox error code.
- `flutter test integration_test/office_test.dart -d macos`: the built macOS app loaded the bundled library and walked to an authorized room through `OfficeCore.findPath`.

Widget tests that use the bridge load the core in `setUpAll` and inject it with a provider override, because generated calls complete on real ports outside the widget test's fake clock.
