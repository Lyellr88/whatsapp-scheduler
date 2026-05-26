# Contributing

This is a small Windows + Node tool. Keep changes practical, local, and easy to test.

## Development Setup

Requirements:

- Windows
- Node.js 18 or newer
- PowerShell
- Pester
- PSScriptAnalyzer
- WhatsApp account that can use WhatsApp Web

From the repo root:

```powershell
npm install
npm link
```

PowerShell validation tools:

```powershell
Install-Module Pester -Scope CurrentUser -Force
Install-Module PSScriptAnalyzer -Scope CurrentUser -Force
```

Authenticate WhatsApp Web:

```powershell
whatsapp-sched --auth
```

Run the scheduler TUI:

```powershell
whatsapp-sched
```

For local development, `npm link` points the global `whatsapp-sched` command at your checkout, so edits take effect immediately.

Do not delete, commit, upload, or share `.wwebjs_auth`. It contains the saved WhatsApp Web session.

## Project Shape

Main runtime files:

- `whatsapp-sched.js` - global CLI command
- `setup_send.ps1` - interactive TUI
- `schedule_send.ps1` - creates Windows scheduled tasks
- `run_queue.ps1` - scheduled-task runner and logger
- `send_whatsapp.js` - WhatsApp Web sender
- `lib/matching.js` - recipient matching logic
- `lib/phone.js` - phone normalization
- `queue.json` - legacy/default queue file
- `queues\` - per-schedule queue files created at runtime
- `logs\` - scheduled run logs created at runtime

The normal flow is:

```text
TUI/CLI -> queue file -> Windows Task Scheduler -> run_queue.ps1 -> send_whatsapp.js
```

Scheduled tasks are named like:

```text
WhatsAppQueueSend-20260525-090000-1234
```

Each scheduled send gets its own queue file and task name, so multiple future send times can coexist.

## Change Guidelines

- Keep the tool Windows-first. Task Scheduler and PowerShell are part of the design.
- Prefer small, direct changes over new abstractions.
- Do not add services, databases, background daemons, or external automation platforms.
- Keep user-facing prompts clear and short; the TUI should remain one-question-at-a-time.
- Avoid changing queue format unless backward compatibility is preserved.
- Never make tests send real WhatsApp messages automatically.
- Never commit runtime state: auth, cache, logs, queues, or local dumps.

## Real WhatsApp Dry Run

Dry-run mode is the safest way to test the real WhatsApp side without sending anything:

```powershell
whatsapp-sched --dry-run
```

It uses the newest pending queue file automatically.

To create a test queue without scheduling it:

```powershell
whatsapp-sched 09:00 "Mike Smith" "Dry run test" --file "C:\path\file.pdf" --no-schedule
```

Then run:

```powershell
whatsapp-sched --dry-run
```

To test a specific queue file:

```powershell
whatsapp-sched --dry-run "C:\tools\whatsapp-scheduler\queues\queue-20260525-090000.json"
```

Dry-run starts WhatsApp Web, uses `.wwebjs_auth`, resolves chats/contacts/phones, validates attachments, and exits without sending messages, removing queue items, or shutting down.

## Queue Format

Queue files are JSON arrays. Each item is one message job:

```json
[
  {
    "recipient": "Mike Smith",
    "message": "Hello *Mike*",
    "attachments": ["C:\\path\\file.pdf"],
    "shutdown": false
  },
  {
    "recipient": "Jane Doe",
    "phone": "15551234567",
    "message": "Hello Jane",
    "attachments": [],
    "shutdown": false
  }
]
```

Successful queue items are removed after they send. If one item fails, that item and anything after it stay in the queue. Per-schedule queue files under `queues\` are removed after they fully complete.

## Logs

Logs are written under:

```text
logs\
```

Useful lines include:

```text
WhatsApp client ready.
Matched "Mike" to WhatsApp chat "Mike Smith".
Text message sent.
Attachment sent: file.pdf
Queue item sent and removed.
Node process exited with code 0.
```

Recipient matching prefers exact and stronger name matches before weaker substring matches. If multiple chats or contacts match with the same confidence, the send fails and asks for a more specific name or phone number instead of guessing.

## Run Lock

Only one WhatsApp send run is allowed at a time. `run_queue.ps1` creates a temporary `.run.lock` folder while it is active.

If two scheduled tasks fire close together, the second run skips and leaves its queue file untouched.

If a previous run crashed and left a lock behind, locks older than 30 minutes are treated as stale and removed automatically.

## Tests

Automated tests should prove behavior without sending WhatsApp messages.

Run the full pre-commit validation pass:

```powershell
npm run validate
```

This runs JavaScript linting, PowerShell syntax checks, PSScriptAnalyzer, and the full test suite.

Run only lint checks:

```powershell
npm run lint
```

Run only JavaScript linting:

```powershell
npm run lint:js
```

Run only PowerShell syntax and PSScriptAnalyzer checks:

```powershell
npm run lint:ps
```

PSScriptAnalyzer warnings are review items. Syntax failures and analyzer errors are blockers.

Run only tests:

```powershell
npm test
```

Run only Node tests:

```powershell
npm run test:node
```

Run only PowerShell/Pester tests:

```powershell
npm run test:ps
```

Some Task Scheduler creation checks may skip when the current shell cannot create Windows scheduled tasks.

Before opening a change, run:

```powershell
npm run validate
npm --cache .\.npm-cache pack --dry-run
```

For changes touching WhatsApp startup, recipient resolution, attachments, auth, or queues, also do a manual dry-run:

```powershell
whatsapp-sched --dry-run
```

For changes touching the actual send path, do one manual smoke test to yourself with a harmless message and `shutdown` set to `n`.

## Packaging

This package is intended for npm. The package allowlist in `package.json` should include only runtime files and user docs.

Do not publish:

- `.wwebjs_auth\`
- `.wwebjs_cache\`
- `logs\`
- `queues\`
- `docs\`
- `tests\`
- `node_modules\`
- `.npm-cache\`

Package contents should stay close to:

```text
CONTRIBUTING.md
CHANGELOG.md
README.md
lib/
package.json
queue.json
run_queue.ps1
schedule_send.ps1
send_whatsapp.js
setup_send.ps1
whatsapp-sched.js
```
