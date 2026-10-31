# Monastack Codex

A self-contained English product brief and implementation prompt for a new Monastack project. The first delivery is a macOS virtual office with department rooms, real collaboration, and an architecture ready for Rust core, AI agents, and local-first sync.

## Start

Open this directory as the Codex workspace. Give Codex [the Stage 1 implementation prompt](prompts/01-build-virtual-office.md). It instructs Codex to read the reference documents and implement the project in this directory. No access to the original Monastack or Nodepass repositories is required.

- [Product vision and roadmap](reference/01-product-and-roadmap.md)
- [Repository architecture](reference/02-architecture.md)
- [Virtual office design and acceptance](reference/03-virtual-office.md)
- [NVIAI seed specification](reference/04-nviai-seed.md)
- [Solution Architect guidance](reference/05-solution-architect-guidance.md)
- [Security and node boundaries](reference/06-security-and-sync.md)
- [Open decisions](reference/07-open-decisions.md)
- [Future-stage prompt](prompts/02-future-stages.md)

The reference documents summarize the existing project; they do not include its code, assets, credentials, or the Nodepass implementation. Building from scratch is authorized. Where implementation or performance claims require verification, the implementing agent must measure and report actual results. The seed contains named people from the user's existing demo dataset; treat it as private project data.

## Current prototype

The workspace now contains a macOS app and a loopback Rust node. The requested roadmap is **not complete**; the current slices, setup commands, verification and security limits are documented in [Stage 1 status](docs/stage-1-status.md), [Stage 2 status](docs/stage-2-status.md), and [Stages 3–6 status](docs/stages-3-6-status.md). These are development prototypes, not production services.
