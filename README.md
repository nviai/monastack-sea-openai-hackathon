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

The workspace contains a macOS app (Flutter/Flame with a Rust core over `flutter_rust_bridge`), a loopback authority/sync node with company setup and password sign-in (the first node set up is the identity master; other nodes join it, ADR 0008), an embedded or separate realtime service for presence and voice control, and a self-hosted LiveKit setup for room voice and camera faces (your webcam replaces your avatar's face for people in the same room). iOS, Android, web, Windows and Linux runners exist only as scaffolds with the app icon; they have not been built or run (ADR 0007). Stage 1 is implemented and verified with automated tests on one Mac; a real-microphone two-person check, two physical Macs and a release build remain to be done manually. See [Stage 1 status](docs/stage-1-status.md) for setup, topology, trust model and tests, [the acceptance tracker](docs/stage-1-acceptance.md), and the decisions in [`docs/adr/`](docs/adr/). Later-stage slices are described in [Stage 2 status](docs/stage-2-status.md) and [Stages 3–6 status](docs/stages-3-6-status.md). These are development prototypes, not production services.

## OpenAI office agents

Office members can chat directly with the six agents using the OpenAI Responses API. Fill `OPENAI_API_KEY` in the `runtime/.env`, restart the office node, and choose **Chat with agent** from an agent profile. See [setup and behavior](docs/openai-agents.md).

## Running the project

Default company/accounts: NVIAI is set up automatically on normal node startup. Sign in with a [seeded username](docs/seeded-accounts.md) and `NviaiSeaxOpenAIHackathon`; no password change is required. Use `MONASTACK_SEED_COMPANY=0` for manual setup or a fresh member node.

Runtime files are grouped under [`runtime/`](runtime/README.md): `runtime/.env`, `runtime/db/`, `runtime/media/`, `runtime/worker/` and `runtime/backups/`.

Same-machine server + member + macOS app: `python3 tools/local_office.py start`. See [ports, logs and lifecycle](docs/local-office.vi.md).

Members now share the master's office records, presence and single LiveKit by default (`MONASTACK_WORKSPACE_MODE=shared`). See [shared office design](docs/adr/0009-shared-office.md).

LAN client: `./tools/start-client.sh` connects to `192.168.224.217:47830`. See [client startup instructions](docs/start-client-lan.vi.md).

## License

This project is licensed under the [MIT License](LICENSE).
