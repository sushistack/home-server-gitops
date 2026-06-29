# English Quest — Setup Runbook

Daily English learning candidate curator: Miniflux RSS → LLM scoring → Anki `English` deck.

**Prerequisite:** Anki LXC (`spec-anki-lxc.md`) must be running and reachable at `http://10.0.0.12:8765`.

---

## 1. Create Credentials in n8n

Go to **Settings → Credentials → New Credential** and create these three:

### Miniflux Header Auth
- Type: **Header Auth**
- Name: `Miniflux Header Auth`
- Name (header): `X-Auth-Token`
- Value: your Miniflux API key

### LLM Bearer
- Type: **Header Auth**
- Name: `LLM Bearer`
- Name (header): `Authorization`
- Value: `Bearer <your_deepseek_or_gemini_key>`

### AnkiConnect API Key
- Type: **Custom Auth**
- Name: `AnkiConnect API Key`
- Add one property: key = `apiKey`, value = your AnkiConnect API key
  (value is in `internal/tokens.env` as `ANKI_API_KEY`)

---

## 2. Import the Workflow

1. In n8n, go to **Workflows → Import from File**
2. Select `english-quest.json`
3. The workflow imports as inactive — activate it after verifying credentials

---

## 3. One-time: Create the EnglishQuest Note Type

Run this from any host that can reach the Anki LXC (replace `<ANKI_API_KEY>` with the value from `internal/tokens.env`):

```bash
curl -s http://10.0.0.12:8765 -d '{
  "action": "createModel",
  "version": 6,
  "key": "<ANKI_API_KEY>",
  "params": {
    "modelName": "EnglishQuest",
    "inOrderFields": [
      "Sentence", "Expression", "Korean", "Intuition",
      "UsageContext", "WhyGood", "SourceTitle", "SourceUrl", "GeneratedAt"
    ],
    "css": "",
    "cardTemplates": [{
      "Name": "Judgement",
      "Front": "{{Sentence}}\n\n<hr>What expression stands out? Why is it effective?",
      "Back": "{{FrontSide}}<hr><b>{{Expression}}</b> — {{Korean}}<br><br><i>{{Intuition}}</i><br><br>{{UsageContext}}<br><br><small>{{WhyGood}}</small><br><br><small>{{SourceTitle}}</small>"
    }]
  }
}'
```

Expected response: `{"result": <model_id>, "error": null}`

---

## 4. Verify Connectivity

From a debug pod in the cluster:

```bash
# AnkiConnect reachable from n8n pod
curl -s http://10.0.0.12:8765 \
  -d '{"action":"version","version":6,"key":"<ANKI_API_KEY>"}' \
  | jq .
# Expected: {"result": 6, "error": null}

# Miniflux reachable
curl -s http://miniflux.miniflux.svc.cluster.local:8080/v1/me \
  -H 'X-Auth-Token: <MINIFLUX_KEY>'
```

---

## 5. Run Once and Verify

1. Open the imported workflow in n8n
2. Click **Execute Workflow** (manual run)
3. Watch the execution log — the "Anki Up?" node should route true
4. After a successful run, open Anki and check the `English` deck for a new card with the `auto-generated` tag
5. After a successful sync, the card should appear on any device synced to `https://anki.eli.kr/`
6. **Toggle the workflow Active ON** (top-right switch in the n8n editor) — the workflow is imported as inactive and will not run on schedule until activated

---

## Card Lifecycle

Cards added to `English` arrive as **New** cards. Standard Anki SRS takes over:
- **Keep**: just review normally — Anki schedules future repetitions automatically
- **Remove**: suspend (`@` in the reviewer) or delete the card
- No second deck, no promotion step needed

---

## Tuning

All tunables are in the **Set Config** node — edit directly in n8n:

| Variable | Default | Notes |
|---|---|---|
| `MIN_SCORE` | `80` | Minimum LLM score to keep a candidate |
| `MAX_DAILY_CANDIDATES` | `1` | Max cards added per day |
| `MINIFLUX_FETCH_LIMIT` | `30` | Entries pulled per run |
| `LLM_API_URL` | DeepSeek | Swap for any OpenAI-compat endpoint |
| `LLM_MODEL` | `deepseek-chat` | Swap for `gemini-...` etc. |

To change the schedule (default 06:00 KST), edit the **Schedule Trigger** node directly.

---

## AnkiConnect & Sync Server

See `spec-anki-lxc.md` for:
- AnkiConnect add-on configuration and API key setup
- LXC IP reservation and reserved-IP guidance
- Sync server (`https://anki.eli.kr/`) client configuration
