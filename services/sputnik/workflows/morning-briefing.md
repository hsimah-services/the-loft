# Workflow — morning briefing

The first workflow worth building: a 7am summary of today's calendar and
overnight mail.

This is a **build spec, not an importable JSON export.** n8n's workflow JSON
pins each node to a `typeVersion`, and a file written against the wrong version
fails to import with an unhelpful error. Building it once in the UI from this
spec takes about ten minutes and cannot go stale the way a checked-in export
would. Export your own JSON afterwards if you want a backup — that one will be
correct by construction.

## Nodes

### 1. Schedule Trigger

- Trigger Interval: **Days**, Days Between Triggers `1`
- Trigger at Hour: **7am**, Trigger at Minute `0`

### 2. Google Calendar — "Today's events"

- Credential: the Google OAuth2 credential
- Resource **Event**, Operation **Get Many**
- Calendar: your primary
- Return All: **on**
- Options → After: `{{ $now.startOf('day').toISO() }}`
- Options → Before: `{{ $now.endOf('day').toISO() }}`

### 3. Gmail — "Overnight mail"

- Same credential
- Resource **Message**, Operation **Get Many**
- Return All: **off**, Limit `25`
- Options → Search: `newer_than:1d -in:chats`
- Simplify: **on** (returns subject/from/snippet without the raw MIME payload)

> The limit and the `newer_than:1d` filter both matter. The model has a 16k
> context; an unbounded fetch will silently overflow it and the summary will
> quietly omit whatever fell out.

### 4. Code — "Build digest"

Runs once for all items. Truncates aggressively — the goal is a compact block
the model can hold entirely in context, not fidelity.

```javascript
const events = $('Today\'s events').all().map(i => i.json);
const mail   = $('Overnight mail').all().map(i => i.json);

const cal = events.length
  ? events.map(e => {
      const start = e.start?.dateTime || e.start?.date || '?';
      return `- ${start} — ${e.summary || '(no title)'}`;
    }).join('\n')
  : '(nothing scheduled)';

const inbox = mail.length
  ? mail.map(m => {
      const from = (m.From || m.from || '?').replace(/<.*>/, '').trim();
      const subj = m.Subject || m.subject || '(no subject)';
      const snip = (m.snippet || '').slice(0, 300);
      return `- ${from}: ${subj}\n  ${snip}`;
    }).join('\n')
  : '(no new mail)';

return [{ json: {
  digest: `CALENDAR (today)\n${cal}\n\nNEW MAIL (last 24h, ${mail.length} messages)\n${inbox}`,
  eventCount: events.length,
  mailCount: mail.length,
}}];
```

### 5. Ollama Chat Model

- Base URL: `http://ollama:11434` — container name on the `loft-proxy` bridge,
  **not** `localhost`, which inside the n8n container is n8n itself
- Model: `sputnik-assistant`

### 6. Basic LLM Chain

Source for Prompt: **Define below**, with:

```
Here is today's calendar and the mail that arrived overnight.

{{ $json.digest }}

Write a briefing, in this order:

1. Today's schedule — one line per event with its time. Say "nothing
   scheduled" if the calendar is empty. Do not pad it out.
2. Mail that plausibly needs a reply today, and why. Name the sender and
   what they want. If nothing does, say so rather than manufacturing an
   item to fill the section.
3. Anything time-sensitive that connects the two — a meeting whose
   prep landed by email overnight, a deadline mentioned in mail that
   falls today.

Skip newsletters, notifications, receipts and automated mail entirely
unless one contains something genuinely time-critical.

Be brief. This is read over coffee, not filed.
```

The persona, the read-only framing and the untrusted-input rules all come from
`sputnik-assistant` itself (see `Modelfile.assistant`) — do not restate them
here, and do not paste them into the n8n prompt field. Keeping them in one
place is the entire reason the model is built rather than configured per
workflow.

## Where the output goes

**The read-only scope means this workflow cannot email you the briefing.** No
`gmail.send`. Pick a delivery route:

| Option | Effort | Notes |
|--------|--------|-------|
| n8n execution log | none | Works today. Open n8n → Executions → read the last run. Fine for validating the workflow, tedious as a daily habit. |
| ntfy | ~30 min | Self-hosted push to phone and desktop. The natural fit for this fleet — one small container, an HTTP Request node, no third party, no new Google scope. |
| Write to a file | ~15 min | Drop it somewhere Homepage can render as a widget. |
| Separate SMTP credential | ~15 min | n8n's Send Email node with its own SMTP account is unrelated to the Gmail OAuth scope, so this does **not** widen the assistant's access. |

Start with the execution log to prove the workflow, then choose. ntfy is the
recommendation — it keeps everything on the LAN and adds no account surface.

## Validating it

Run it manually before trusting the schedule, and check the digest the Code
node produced against what the model said about it. The failure mode to watch
for is fabricated detail — a sender or time that appears in the summary but not
in the digest. That means the digest overflowed the context window; reduce the
Gmail limit or the snippet length rather than raising `num_ctx`.

Expect roughly 60–120 seconds per run on CPU. Nobody is watching, so this does
not matter — but do not mistake it for a hang.
