---
title: 'Daily English learning candidate curator (english-quest, n8n)'
type: 'feature'
created: '2026-06-29'
status: 'done'
baseline_commit: 'bc228f1ebde4ea46881683fd564344eba988ec0e'
context:
  - '{project-root}/workloads/n8n/'
  - '{project-root}/workloads/miniflux/service.yaml'
  - '{project-root}/_bmad-output/implementation-artifacts/spec-anki-lxc.md'
---

<!-- DEPENDS ON spec-anki-lxc.md: the AnkiConnect target (Proxmox LXC) must be built and reachable first. -->


<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** Plenty of English RSS flows through Miniflux, but nothing surfaces the few sentences actually worth re-using in real work. Manual curation never happens; notes pushed to a separate app are never reopened.

**Approach:** Build an **n8n workflow** (n8n is the standard automation hub) that runs once daily: pull recent Miniflux entries → ask a pluggable OpenAI-compatible LLM to extract and score reusable sentences → keep only score ≥ MIN_SCORE → push the top 1–3 into the Anki `English` deck via AnkiConnect as New cards. The workflow definition is committed to Git as importable JSON (Git = source of truth; n8n imports it). Secrets live in n8n Credentials; tunables live in a Set node. Anki is the single learning entry point — Jay reviews new cards naturally via SRS, suspends/deletes bad ones; no second deck needed.

## Boundaries & Constraints

**Always:**
- Deliver `workloads/n8n/workflows/english-quest.json` (importable n8n workflow) + `workloads/n8n/workflows/README.md` (setup runbook). These are **versioned repo artifacts, NOT k8s manifests** — do NOT add them to any `kustomization.yaml`; ArgoCD does not sync them.
- Node graph (in order): **Schedule Trigger** (daily, hour from Set/`SCHEDULE_HOUR`, TZ Asia/Seoul) → **Set "Config"** (`MIN_SCORE=80`, `MAX_DAILY_CANDIDATES=1`, `TARGET_DECK="English"`, `MODEL_NAME="EnglishQuest"`, `MINIFLUX_FETCH_LIMIT=30`, `MINIFLUX_API_URL`, `ANKI_CONNECT_URL`, `LLM_API_URL`, `LLM_MODEL`) → **HTTP "Anki ping"** (`{action:"version",version:6}`, *continue-on-fail*) → **IF "Anki up?"** (false → NoOp stop, before any LLM call) → **HTTP "Miniflux entries"** (`GET {MINIFLUX_API_URL}/v1/entries?status=unread&direction=desc&limit={MINIFLUX_FETCH_LIMIT}`, Header-Auth credential `X-Auth-Token`) → **Code "Build prompt"** (strip HTML, truncate each entry, assemble messages) → **HTTP "LLM"** (`POST {LLM_API_URL}` chat/completions, Bearer credential, body `{model, messages}`) → **Code "Parse+rank"** (parse JSON array, drop `score < MIN_SCORE`, sort desc, slice `MAX_DAILY_CANDIDATES`, emit one item per candidate) → **HTTP "createDeck"** (idempotent) → **HTTP "findNotes"** (dedup) → **IF "new?"** → **HTTP "addNote"** → **HTTP "sync"** (push to the self-hosted sync server so devices pull the new card). Every AnkiConnect HTTP node includes the `key` (apiKey) param from a credential.
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
- No Anytype / external note app; no second deck (`English::Real` concept dropped — one deck only); no ntfy, dashboard, weekly report (deferred).
- No PVC/DB seen-set; no auto-import machinery (import is manual for MVP).

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Happy path | ≥1 entry, LLM returns ≥1 candidate ≥ MIN_SCORE, Anki up | Top-N new candidates added to `English` | N/A |
| Anki down | ping `version` fails | IF routes to NoOp stop, before LLM call | continue-on-fail + IF |
| Duplicate expression | `findNotes` returns ≥1 | Candidate skipped, no `addNote` | IF "new?" false branch |
| LLM non-JSON | content not a JSON array | Parse node throws → workflow errors visibly in n8n; nothing added | try/catch in Code node, throw clean message |
| All below MIN_SCORE | only low scores | 0 added; parse node emits no items | empty → downstream no-op |
| Miniflux empty/4xx | no entries / API error | Build-prompt sees empty → stop; or HTTP error shown | continue-on-fail on Miniflux node |

</frozen-after-approval>

## Code Map

- `workloads/n8n/` -- n8n deployment manifests (reference only — do NOT edit); confirms `N8N_BLOCK_ENV_ACCESS_IN_NODE=false`, TZ=Asia/Seoul, n8n 2.23.4
- `workloads/n8n/workflows/` -- **does not exist yet** — create this directory with `english-quest.json` + `README.md`
- `workloads/miniflux/service.yaml` -- ClusterIP `miniflux.miniflux.svc.cluster.local:8080` → use as `MINIFLUX_API_URL` value in Set node
- `_bmad-output/implementation-artifacts/spec-anki-lxc.md` -- AnkiConnect LXC details (IP, port, API key token, sync server URL, EnglishQuest note type curl)

## Tasks & Acceptance

**Execution:**
- [x] `workloads/n8n/workflows/english-quest.json` -- Create the full importable n8n workflow JSON with all nodes wired in order: Schedule Trigger → Set "Config" → HTTP "Anki ping" → IF "Anki up?" → HTTP "Miniflux entries" → Code "Build prompt" → HTTP "LLM" → Code "Parse+rank" → HTTP "createDeck" → HTTP "findNotes" → IF "new?" → HTTP "addNote" → HTTP "sync". Set node concrete values: `ANKI_CONNECT_URL=http://10.0.0.12:8765`, `MINIFLUX_API_URL=http://miniflux.miniflux.svc.cluster.local:8080`, `MIN_SCORE=80`, `MAX_DAILY_CANDIDATES=1`, `TARGET_DECK=English`, `MODEL_NAME=EnglishQuest`, `MINIFLUX_FETCH_LIMIT=30`. All credentials referenced by name only (never inline). Build-prompt Code node: strip HTML, truncate entries to ~300 chars each, assemble `messages` array with system prompt encoding selection criteria + scoring rubric + JSON-array output schema (`sentence, expression, korean_translation, intuition, usage_context, why_good, score, source_title, source_url`). Parse+rank Code node: JSON.parse, filter `score >= MIN_SCORE`, sort desc, slice `MAX_DAILY_CANDIDATES`, `$input.item` emit per candidate; wrap in try/catch throwing clean message on parse failure.
- [x] `workloads/n8n/workflows/README.md` -- Setup runbook: (1) import JSON via n8n UI; (2) create 3 credentials — Miniflux Header Auth (`X-Auth-Token`), LLM HTTP Header Auth (`Authorization: Bearer <key>`), AnkiConnect plain-text credential (apiKey value from `internal/tokens.env`); (3) one-time `createModel` curl block for EnglishQuest note type (9 fields + Judgement card template with Front/Back per spec-anki-lxc.md); (4) how to run-once manually and verify a card lands in `English`; (5) reference `spec-anki-lxc.md` for LXC IP, AnkiConnect addon config, sync server — do not redefine them here.

**Acceptance Criteria:**
- Given `english-quest.json`, when `jq empty workloads/n8n/workflows/english-quest.json` runs, then it exits 0 (valid JSON).
- Given `english-quest.json`, when `grep -iE 'api[_-]?key|secret|bearer [A-Za-z0-9]|X-Auth-Token: [A-Za-z0-9]' workloads/n8n/workflows/english-quest.json` runs, then it finds no secret literals (credential refs only).
- Given the LLM returns three candidates (scores 92, 78, 85) with `MAX_DAILY_CANDIDATES=1`, when Parse+rank runs, then only score-92 reaches `addNote` (78 dropped below MIN_SCORE, 85 dropped by daily cap).
- Given a candidate whose `Expression` already exists in `English`, when `findNotes` returns ≥1 result, then the IF "new?" false branch skips `addNote`.
- Given AnkiConnect is unreachable, when the workflow runs, then the "Anki up?" IF stops before the LLM node executes (LLM node not in execution log).
- Given the README runbook is followed end to end, when the workflow is run once manually, then exactly one new note appears in `English` with the Judgement Front/Back layout.

## Spec Change Log

- **2026-06-29 (human renegotiation):** Dropped `English::Candidate` / `English::Real` two-deck model. Single `English` deck only — new cards added by workflow are Anki's native "New" state; Jay suspends/deletes bad ones during normal SRS review. Eliminates manual deck-move friction. `TARGET_DECK` updated to `"English"` everywhere.

## Design Notes

- **Why JSON-in-Git, not auto-sync:** n8n community edition (2.23.4 deployed) has no native Git sync (Enterprise feature). The committed JSON is the versioned source of truth; import is a documented manual step. Acceptable for homelab; revisit only if drift becomes painful.
- **One pluggable LLM call:** OpenAI-compatible chat/completions. DeepSeek (`https://api.deepseek.com/chat/completions`) and Gemini's OpenAI-compat endpoint both fit by changing the credential + Set values. Add a branch only if a non-compatible API is introduced.
- **EnglishQuest note type (9 fields):** `Sentence, Expression, Korean, Intuition, UsageContext, WhyGood, SourceTitle, SourceUrl, GeneratedAt`. Created once via curl (kept out of the workflow JSON to keep it lean); the workflow only does `createDeck` (idempotent) + `addNote`.
- **Dedup escaping caveat:** `findNotes` query embeds `<expr>` inside quotes; expressions containing a `"` must be escaped in the Parse+rank Code node before building the query string.
- **LLM prompt construction:** music-curator has no LLM prompt to reuse — write the scoring rubric from scratch. Criteria: native-sounding collocation or idiom, broadly reusable in professional writing, not overly domain-specific.

## Verification

**Commands:**
- `jq empty workloads/n8n/workflows/english-quest.json` -- expected: exits 0
- `grep -iE 'api[_-]?key|secret|bearer [A-Za-z0-9]|X-Auth-Token: [A-Za-z0-9]' workloads/n8n/workflows/english-quest.json` -- expected: no output (no secret literals)

## Resolved Context (from spec-anki-lxc.md — 2026-06-29)

> LXC is live. Use these exact values; no discovery needed.

**Anki LXC:**
- Proxmox LXC 202, LAN IP `10.0.0.12` (token name: `IP_ANKI_LXC` in `internal/tokens.env`)
- AnkiConnect listening on `:8765`, verified: `{"result":6,"error":null}`
- AnkiConnect API key token name: `ANKI_API_KEY` (see `internal/tokens.env` for the actual value — do **not** put it in the workflow JSON)
- Self-hosted sync server public URL: `https://anki.eli.kr/` (Traefik + LE cert, no CF Access)

**Set node concrete values:**
```
ANKI_CONNECT_URL  = http://10.0.0.12:8765
MINIFLUX_API_URL  = http://miniflux.miniflux.svc.cluster.local:8080
```
n8n pods are on the same LAN (10.0.0.0/24, vmbr1); direct TCP to `10.0.0.12:8765` works with no tunnel.

**Sync node action:**
AnkiConnect's `sync` action pushes the headless Anki instance to `https://anki.eli.kr/`:
```json
{"action":"sync","version":6,"key":"<ANKI_API_KEY value>"}
```

**EnglishQuest note type (one-time, not yet created):**
Run from any host that can reach the LXC (or include in the README curl block). API key value from `internal/tokens.env`:
```bash
curl -s http://10.0.0.12:8765 -d '{
  "action": "createModel",
  "version": 6,
  "key": "<ANKI_API_KEY>",
  "params": {
    "modelName": "EnglishQuest",
    "inOrderFields": ["Sentence","Expression","Korean","Intuition","UsageContext","WhyGood","SourceTitle","SourceUrl","GeneratedAt"],
    "css": "",
    "cardTemplates": [{
      "Name": "Judgement",
      "Front": "{{Sentence}}\n\n<hr>What expression stands out? Why is it effective?",
      "Back": "{{FrontSide}}<hr><b>{{Expression}}</b> — {{Korean}}<br><br><i>{{Intuition}}</i><br><br>{{UsageContext}}<br><br><small>{{WhyGood}}</small><br><br><small>{{SourceTitle}}</small>"
    }]
  }
}'
```

**n8n credential names to create (README must document these):**
1. **Miniflux Header Auth** — Header: `X-Auth-Token`, value from n8n Credential (never in JSON)
2. **LLM Bearer** — `Authorization: Bearer <key>`, HTTP Header Auth credential
3. **AnkiConnect API key** — plain text credential holding the `ANKI_API_KEY` value; referenced in every AnkiConnect HTTP node as the `key` param

## Suggested Review Order

**Core pipeline logic**

- Parse Rank: filter ≥80, sort desc, slice MAX_DAILY, build Anki dedup query
  [`english-quest.json:187`](../../workloads/n8n/workflows/english-quest.json#L187)

- Build Prompt: HTML strip, FETCH_LIMIT-aware slice, system prompt + user message
  [`english-quest.json:148`](../../workloads/n8n/workflows/english-quest.json#L148)

- New? IF: null-safe dedup gate (`($json.result || []).length === 0`)
  [`english-quest.json:262`](../../workloads/n8n/workflows/english-quest.json#L262)

**Anki fault tolerance**

- Anki Up? IF: circuit breaker (number > 0) stops run before any LLM call
  [`english-quest.json:79`](../../workloads/n8n/workflows/english-quest.json#L79)

- LLM node: `continueOnFail:true` + Parse Rank guard `if ($json.error) return []`
  [`english-quest.json:153`](../../workloads/n8n/workflows/english-quest.json#L153)

**Credential injection & note fields**

- All AnkiConnect nodes use `$credentials.apiKey` via `httpCustomAuth` — verify field name matches
  [`english-quest.json:68`](../../workloads/n8n/workflows/english-quest.json#L68)

- Add Note: `$('Parse Rank').item.json.*` cross-node item pairing for 9 fields + `$now.toISO()`
  [`english-quest.json:294`](../../workloads/n8n/workflows/english-quest.json#L294)

**Config & tunables**

- Set Config: all tunables (TARGET_DECK, MIN_SCORE, MAX_DAILY_CANDIDATES, URLs)
  [`english-quest.json:24`](../../workloads/n8n/workflows/english-quest.json#L24)

**Setup runbook**

- Credentials to create (3): Miniflux Header Auth, LLM Bearer, AnkiConnect Custom Auth
  [`README.md:11`](../../workloads/n8n/workflows/README.md#L11)

- One-time createModel curl for EnglishQuest note type (9 fields + Judgement template)
  [`README.md:30`](../../workloads/n8n/workflows/README.md#L30)
