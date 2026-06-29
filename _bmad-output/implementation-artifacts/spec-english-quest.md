---
title: 'Daily English learning candidate curator (english-quest, n8n)'
type: 'feature'
created: '2026-06-29'
status: 'draft'
context:
  - '{project-root}/workloads/n8n/'
  - '{project-root}/workloads/miniflux/service.yaml'
  - '{project-root}/_bmad-output/implementation-artifacts/spec-anki-lxc.md'
---

<!-- DEPENDS ON spec-anki-lxc.md: the AnkiConnect target (Proxmox LXC) must be built and reachable first. -->


<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** Plenty of English RSS flows through Miniflux, but nothing surfaces the few sentences actually worth re-using in real work. Manual curation never happens; notes pushed to a separate app are never reopened.

**Approach:** Build an **n8n workflow** (n8n is the standard automation hub) that runs once daily: pull recent Miniflux entries → ask a pluggable OpenAI-compatible LLM to extract and score reusable sentences → keep only score ≥ MIN_SCORE → push the top 1–3 into the Anki `English::Candidate` deck via AnkiConnect. The workflow definition is committed to Git as importable JSON (Git = source of truth; n8n imports it). Secrets live in n8n Credentials; tunables live in a Set node. Anki is the single learning entry point.

## Boundaries & Constraints

**Always:**
- Deliver `workloads/n8n/workflows/english-quest.json` (importable n8n workflow) + `workloads/n8n/workflows/README.md` (setup runbook). These are **versioned repo artifacts, NOT k8s manifests** — do NOT add them to any `kustomization.yaml`; ArgoCD does not sync them.
- Node graph (in order): **Schedule Trigger** (daily, hour from Set/`SCHEDULE_HOUR`, TZ Asia/Seoul) → **Set "Config"** (`MIN_SCORE=80`, `MAX_DAILY_CANDIDATES=1`, `TARGET_DECK="English::Candidate"`, `MODEL_NAME="EnglishQuest"`, `MINIFLUX_FETCH_LIMIT=30`, `MINIFLUX_API_URL`, `ANKI_CONNECT_URL`, `LLM_API_URL`, `LLM_MODEL`) → **HTTP "Anki ping"** (`{action:"version",version:6}`, *continue-on-fail*) → **IF "Anki up?"** (false → NoOp stop, before any LLM call) → **HTTP "Miniflux entries"** (`GET {MINIFLUX_API_URL}/v1/entries?status=unread&direction=desc&limit={MINIFLUX_FETCH_LIMIT}`, Header-Auth credential `X-Auth-Token`) → **Code "Build prompt"** (strip HTML, truncate each entry, assemble messages) → **HTTP "LLM"** (`POST {LLM_API_URL}` chat/completions, Bearer credential, body `{model, messages}`) → **Code "Parse+rank"** (parse JSON array, drop `score < MIN_SCORE`, sort desc, slice `MAX_DAILY_CANDIDATES`, emit one item per candidate) → **HTTP "createDeck"** (idempotent) → **HTTP "findNotes"** (dedup) → **IF "new?"** → **HTTP "addNote"** → **HTTP "sync"** (push to the self-hosted sync server so devices pull the new card). Every AnkiConnect HTTP node includes the `key` (apiKey) param from a credential.
- Secrets ONLY as n8n Credentials (Miniflux `X-Auth-Token` header; LLM `Authorization: Bearer`; AnkiConnect `apiKey` value). No secret literal in the workflow JSON, the README, or Git.
- AnkiConnect target is the **Proxmox LXC** (see `spec-anki-lxc.md`): `ANKI_CONNECT_URL=http://<anki-lxc-LAN-IP>:8765`, always-on, reached from the n8n pod over the LAN. The `EnglishQuest` note type is created once by the LXC runbook, NOT by this workflow.
- LLM call uses the OpenAI-compatible chat/completions schema so DeepSeek and Gemini-compat both work by swapping the credential + `LLM_API_URL`/`LLM_MODEL` Set values. No per-provider node branching.
- Stateless dedup via AnkiConnect `findNotes` query `deck:"<TARGET_DECK>" "Expression:<expr>"`; non-empty result → skip that candidate (no `addNote`).
- `addNote` uses `deckName=TARGET_DECK`, `modelName=MODEL_NAME`, `options.allowDuplicate=false`, tags `auto-generated daily-candidate rss topdown feynman-lite`, and the 9 fields (`Sentence, Expression, Korean, Intuition, UsageContext, WhyGood, SourceTitle, SourceUrl, GeneratedAt`). `GeneratedAt` = run timestamp via n8n expression.
- README documents: import steps and the 3 credentials to create (Miniflux `X-Auth-Token`, LLM Bearer, AnkiConnect apiKey). The `EnglishQuest` note type, AnkiConnect addon config, and the LXC IP all come from `spec-anki-lxc.md` — this README only references them, does not redefine them.

**Ask First:**
- The Anki LXC IP must exist and be reachable before this workflow is useful — build `spec-anki-lxc.md` first. Confirm `ANKI_CONNECT_URL` and that pods can reach the LXC over the LAN.
- Changing the daily schedule (default 06:00 KST) or raising `MAX_DAILY_CANDIDATES` above 3.

**Never:**
- No Python/APScheduler workload — logic is the n8n workflow, versioned as JSON.
- No edits to `workloads/n8n/` manifests (configmap/sealedsecret/deployment) — config/secrets stay in n8n Credentials + Set node, not the n8n pod env.
- No Anytype / external note app; no `English::Real` auto-promotion; no ntfy, dashboard, weekly report (deferred).
- No PVC/DB seen-set; no auto-import machinery (import is manual for MVP).

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Happy path | ≥1 entry, LLM returns ≥1 candidate ≥ MIN_SCORE, Anki up | Top-N new candidates added to `English::Candidate` | N/A |
| Anki down | ping `version` fails | IF routes to NoOp stop, before LLM call | continue-on-fail + IF |
| Duplicate expression | `findNotes` returns ≥1 | Candidate skipped, no `addNote` | IF "new?" false branch |
| LLM non-JSON | content not a JSON array | Parse node throws → workflow errors visibly in n8n; nothing added | try/catch in Code node, throw clean message |
| All below MIN_SCORE | only low scores | 0 added; parse node emits no items | empty → downstream no-op |
| Miniflux empty/4xx | no entries / API error | Build-prompt sees empty → stop; or HTTP error shown | continue-on-fail on Miniflux node |

</frozen-after-approval>

## Code Map

- `workloads/n8n/configmap.yaml` -- confirms `N8N_BLOCK_ENV_ACCESS_IN_NODE=false` and host/TZ; no edits needed (reference only)
- `workloads/miniflux/service.yaml` -- ClusterIP `miniflux.miniflux.svc.cluster.local:8080` for `MINIFLUX_API_URL`
- `workloads/music-curator/configmap.yaml` -- prior LLM-prompt + scoring rubric wording to reuse in the Build-prompt node

## Tasks & Acceptance

**Execution:**
- [ ] `workloads/n8n/workflows/english-quest.json` -- the full importable n8n workflow: all nodes above wired in order, the Set "Config" node, the Build-prompt Code node (HTML strip + truncate + the selection-criteria/topic-priority/scoring-rubric prompt encoding the JSON-array output schema: `sentence, expression, korean_translation, intuition, usage_context, why_good, score, source_title, source_url`), and the Parse+rank Code node. Credential references by name, never inline secrets.
- [ ] `workloads/n8n/workflows/README.md` -- setup runbook: import the JSON; create credentials (Miniflux Header-Auth, LLM Bearer); one-time `createModel` curl for the `EnglishQuest` note type (9 fields + Front/Back card template per the card spec); AnkiConnect addon config + reserved-IP guidance; how to run-once and verify a card lands in `English::Candidate`.

**Acceptance Criteria:**
- Given `english-quest.json`, when `jq empty workloads/n8n/workflows/english-quest.json` runs, then it is valid JSON, and `grep -iE 'api[_-]?key|token|bearer [A-Za-z0-9]' english-quest.json` finds no secret literal.
- Given the LLM returns three candidates (scores 92, 78, 85) with `MAX_DAILY_CANDIDATES=1`, when the workflow runs, then only the score-92 sentence reaches `addNote` (78 dropped < MIN_SCORE, 85 dropped by daily cap).
- Given a candidate whose `Expression` already exists in `English::Candidate`, when the workflow runs, then `findNotes` matches and the IF "new?" false branch skips `addNote`.
- Given AnkiConnect is unreachable, when the workflow runs, then the "Anki up?" IF stops the run before the LLM HTTP node executes (verifiable in the n8n execution log: LLM node not executed).
- Given the README runbook is followed end to end, when the workflow is run once manually, then exactly one new note appears in the `English::Candidate` deck with the judgement Front/Back layout.

## Design Notes

- **Why JSON-in-Git, not auto-sync:** n8n community edition has no native Git sync (Enterprise feature). The committed JSON is the versioned source of truth; import is a documented manual step. Acceptable for a homelab; revisit only if drift becomes painful.
- **One pluggable LLM call:** target OpenAI-compatible chat/completions. DeepSeek (`https://api.deepseek.com/chat/completions`) and Gemini's OpenAI-compat endpoint both fit by changing the credential + Set values. Add a branch only if a non-compatible API is introduced.
- **Custom note type `EnglishQuest`:** 9 fields map 1:1 to the JSON schema so cards stay structured for a future `English::Real` promotion. Created once via curl (kept out of the workflow to keep the JSON lean); the workflow only `createDeck` (idempotent) + `addNote`.
- **Dedup escaping caveat:** the `findNotes` query embeds `<expr>` inside quotes; expressions containing a `"` must be escaped in the Code node before building the query. Most expressions are short phrases without quotes.

## Verification

**Commands:**
- `jq empty workloads/n8n/workflows/english-quest.json` -- expected: exits 0 (valid JSON)
- `grep -iE 'api[_-]?key|secret|bearer [A-Za-z0-9]|X-Auth-Token: [A-Za-z0-9]' workloads/n8n/workflows/english-quest.json` -- expected: no secret values (credential refs only)

**Manual checks:**
- Import the JSON into n8n; from a debug pod `curl -s $ANKI_CONNECT_URL -d '{"action":"version","version":6,"key":"<apiKey>"}'` returns a version (confirms the LXC is reachable over the LAN); run the workflow once and confirm a card lands in `English::Candidate` and, after the `sync` node, appears on a synced device.
