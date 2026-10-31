# Product vision and roadmap

Monastack brings a company's operational and product information into one workspace. People and AI agents participate as coworkers: they have identities, roles, responsibilities, communication, tasks, and an auditable work history. Humans can interact with an agent through the virtual office, task board, chat, or Mona, rather than needing to operate a CLI. A Dev Agent will eventually use Codex CLI through a controlled runner. All interfaces refer to the same underlying records and authorization rules.

## Confirmed decisions

- macOS desktop is the first supported platform. Other platforms are future work.
- Implement the virtual office and communication first, including rooms for departments such as Dev, HR, and Sales.
- Flutter is the app UI, Riverpod is the state manager, Flame is the starting point for the world renderer, and reusable domain/core logic should live in Rust where appropriate. Organize app, core, and backend by feature.
- A sync node handles sync and backup. A separate optional process node runs the shared core and authorized agents/processes around the clock. An agent can instead run on the user's Mac while its host is running. Voice/presence infrastructure may be a separate capability.
- No migration or preservation of the old database is required. Seed a new NVIAI workspace using the supplied reference, including the existing people and agents. Do not interpret this as permission to delete any unrelated files or data.
- Stage 1 needs the minimum identity, permissions, storage, sync, presence and media foundations required for a real office. It does not require a full agent runtime, task board, MCP gateway, or all later departments' business tools.

## Stages

1. **Virtual office and communication:** visually polished 2.5D office, department rooms, identities, presence, chat, voice, authorization, seed, and minimum viable node topology. See `03-virtual-office.md` for acceptance.
2. **Tasks and workflow:** projects, boards, issues, assignments to people/agents, state transitions, comments, audit, and links from the office.
3. **Mona and Dev Agent:** real agent identities, permissions, durable jobs, approval, bounded Codex runner on a local Mac or process node, cancellation, reports and PR workflow, and MCP access.
4. **Knowledge, collaboration and edge AI:** documents, search with permission filtering, calendar, meetings, whiteboard, and pluggable local/cloud inference with measured hardware requirements.
5. **Customer and sales:** CRM, customer care, sales, contracts, booking and integrations.
6. **HR, finance and operations:** sensitive HR data, expenses, accounting, payments, incidents and approvals with appropriate authority and separation of duties.
7. **Hardening and further platforms:** security review, backup recovery, performance, accessibility, release, operations, and a tested platform matrix.

Build each stage as a usable vertical slice with permission checks, tests and documentation. Feature order after Stage 1 can change with product priorities. Agent/model behavior is real only if an actual configured runtime executes it; seed personas and placeholders must not pretend otherwise.
