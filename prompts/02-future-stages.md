# Prompt: Continue with a later Monastack stage

Use this only after Stage 1, or when the user explicitly selects another stage. Replace `<STAGE>` with the requested stage.

---

Continue implementing Monastack in this repository. The requested stage is **<STAGE>**, as described in `reference/01-product-and-roadmap.md`. Read `README.md`, `reference/`, current architecture/ADRs, code, test results and git status before changes; the user's latest instructions and actual code state take precedence over old plans. Preserve existing user changes.

Implement a working vertical slice with Flutter/Riverpod presentation, Rust domain/application logic, node capabilities where required, versioned contracts, scoped identity/permissions, audit and meaningful tests. Maintain a single source of truth for records shared by the office, task board, Mona and agents. State clearly which capabilities are real versus simulated. Reuse app-hosted and process-node-hosted core boundaries, and keep the sync node limited to synchronization and backup.

For Tasks, implement projects, board, assignments, state transitions, comments and audit, including offline and conflict behavior appropriate to the domain. For agents, implement durable job ownership, scoped permissions, approvals, budgets, cancellation and kill switch, and a real isolated Codex runner only when explicitly configured; report status and results back to the user through the app. For knowledge/edge AI, enforce document/search permissions and test a concrete local model/runtime on target hardware before claiming local inference. Later CRM, HR, finance and operations require their own access rules and online authority for sensitive actions.

Update ADRs, runbooks, seed where relevant and a capability/test matrix. Run appropriate automated and integration checks; report exact results and blockers. Do not deploy, send data outside the workspace, delete unrelated data or commit unless explicitly requested.
