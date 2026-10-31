# ADR 0002: Feature-based Flutter layout

Status: accepted.

`app/lib` was a flat directory of 28 files. It now follows the layout in `reference/02-architecture.md`:

```text
lib/main.dart                 entry point only
lib/app/                      MaterialApp, office shell and composition
lib/platform/                 native library location and Rust core calls
lib/shared/                   node request contract and UTC helpers
lib/features/
  office/{world,presence,communication,rooms}/
  organization/ agents/ tasks/ sync/ inference/
  knowledge/ customers/ finance/ hr/ operations/
```

Features import `shared/` and `platform/`, not each other's internals. The `TaskRequest` typedef, which most later-stage views imported from the task board only to describe a node call, became `NodeRequest` in `shared/node_request.dart` together with `NodeFailure`. The UTC helpers moved out of the meetings view for the same reason. Remaining cross-feature imports are deliberate compositions: the office communication panel opens the other feature views, and the task board opens agent proposals.

`presentation/application/data/domain` subdirectories are not created for features that currently consist of one widget file; empty layers would only add indirection. They are introduced when a feature gains a separate data adapter or application coordinator (for example, the bridge adapters in the office feature).

Evidence: `flutter analyze` reports no issues and all 76 `flutter test` tests pass after the move.
