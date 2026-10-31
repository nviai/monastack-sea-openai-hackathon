# Monastack pitch deck

English pitch deck for the **Sea × OpenAI Codex Hackathon, Vietnam 2026** (https://codexhackathon.sea.com).

| File | Purpose |
| --- | --- |
| `index.html` | The deck. Self-contained (no network, no build step) with 16 slides at 1920×1080. |
| `monastack-pitch.pdf` | PDF export to keep as a backup or submit. |

## Presenting

Open `index.html` in Chrome.

- `→` / `Space` / click right half: next slide. `←` / click left half: previous slide.
- `F` toggles fullscreen. `N` toggles the speaker-notes panel.
- `index.html#7` opens slide 7 directly.

Re-export the PDF after editing:

```sh
"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" --headless=new --no-pdf-header-footer \
  --print-to-pdf=pitch/monastack-pitch.pdf "file://$PWD/pitch/index.html"
```

## Storyline (about 5–7 minutes)

1. **Title.** Mono + AI + Stack, mapped to the three hackathon directions.
2. **The moment.** `morluto/rea` shows agents can rebuild almost any app, but rebuilt apps still have human UIs.
3. **Insight.** Humans and agents perceive a company differently, so the data layer becomes the product.
4. **Problem 1.** Fragmented SaaS stack. The "one project" trend relocates the mess without cleaning it.
5. **Problem 2.** Ten context failure modes that lead to hallucination.
6. **Solution.** Three pillars: clean by construction, agents as coworkers, edge-first mesh.
7. **Open source + MCP.** Matrix, WebRTC/LiveKit, Chatwoot, Twenty, Odoo/ERPNext, Forgejo, MLX/llama.cpp/Ollama, Rust/Flutter.
8. **Canonical schema.** Schema gate → clean ledger → context packs, with a record envelope example.
9. **Virtual office.** Talk to agents like colleagues.
10. **A morning with Mona.** One instruction fans out to several agents, with guardrails.
11. **NVIAI architecture.** Edge sites, process node, media node, peer data replicas and LLM nodes for frontier models.
12. **Routing.** Edge vs process node vs frontier, with a measured local-model result.
13. **Evidence.** What is built, what was tested in isolation, and what isn't done yet.
14. **Codex.** How we build with Codex, and Codex as the Dev Agent's sandboxed engine.
15. **Roadmap.** Seven stages.
16. **Close.** "Stop rebuilding apps for humans. Build the company for agents."

## Where the numbers come from

Each figure in the deck is taken from this repository, so update the deck if these sources change.

- ~60 fps and p95 build 0.95 ms (idle debug run on Apple M6): `docs/stage-1-status.md`
- Qwen3-0.6B-4bit: 0.32 s load, ~352 tok/s, 0.5 GB peak: `docs/local-model-spike.md`
- Codex CLI 0.164 in a networkless container: `docs/codex-evaluation.md`, `docs/process-host-spike.md`
- LiveKit room-epoch isolation: `docs/media-evaluation.md`
- Built / tested / not-yet status: `docs/capability-matrix.md`
- ~22k lines (Dart 12.1k, Rust 7.8k, Python 2.2k) and 35 test files were counted from `app/`, `core/`, `backend/` and `tools/`.
- The `morluto/rea` description and ~408k stars come from its GitHub page as of 2026-10-30.

Open-source projects on slide 7 marked **Plan** are integration targets that aren't in the prototype yet. The private seed names of real staff are deliberately left out of the deck.
