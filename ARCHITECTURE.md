# WhatsApp Scheduled Messenger Architecture

## Executive Summary

WhatsApp Scheduled Messenger is a local Windows automation tool for scheduling WhatsApp messages and file attachments.

It exists because WhatsApp does not provide a simple personal scheduling API. The tool uses `whatsapp-web.js` to control a local Chromium instance through Puppeteer, then relies on Windows Task Scheduler for delayed execution.

The architecture avoids hosted services, databases, and cloud automation. Queue state is stored in local JSON files, and session persistence is handled through `.wwebjs_auth`, which must remain private to the host machine.

Key features include:

- interactive TUI queue creation
- fast CLI queue creation
- scheduled one-time Windows tasks
- fuzzy recipient matching
- phone-number fallback for new contacts
- attachment validation
- dry-run validation without sending
- run locking to avoid concurrent Chromium sessions
- optional shutdown after successful delivery

## System Components

The project is split between Node.js and PowerShell:

- Node.js handles WhatsApp Web automation.
- PowerShell handles Windows scheduling, TUI prompts, runner logging, and system integration.

| File | Language | Primary Function |
| --- | --- | --- |
| `whatsapp-sched.js` | Node.js | Global CLI entrypoint for creating queues, auth, dry-run, and status. |
| `setup_send.ps1` | PowerShell | Interactive TUI for message setup. |
| `schedule_send.ps1` | PowerShell | Registers one-time Windows Task Scheduler jobs. |
| `run_queue.ps1` | PowerShell | Task Scheduler runner that locks, logs, and calls the sender. |
| `send_whatsapp.js` | Node.js | Authenticates, resolves recipients, sends messages, and drains queues. |
| `lib/matching.js` | Node.js | Recipient name normalization and match scoring. |
| `lib/phone.js` | Node.js | Phone-number normalization. |

Runtime state lives outside the package source:

| Path | Purpose |
| --- | --- |
| `queues/` | Per-schedule queue files. |
| `logs/` | Scheduled run logs. |
| `.wwebjs_auth/` | Saved WhatsApp Web session. Private. |
| `.wwebjs_cache/` | WhatsApp Web cache. |
| `.run.lock/` | Temporary run lock. |
| `queue.json` | Legacy/default queue path. |

## Execution Flow

The system does not run as a continuous background daemon.

1. The user creates a queue with the TUI or CLI.
2. The queue is written as JSON under `queues/`.
3. `schedule_send.ps1` creates a one-time Windows scheduled task.
4. At the scheduled time, Task Scheduler runs `run_queue.ps1`.
5. `run_queue.ps1` acquires `.run.lock`, writes logs, and launches `send_whatsapp.js`.
6. `send_whatsapp.js` starts WhatsApp Web, resolves each recipient, sends messages and attachments, then removes successful queue items.
7. If the queue fully drains, the completed per-schedule queue file is removed.

If a queue item fails, that item and any later items remain in the queue. The failed item is stamped with `lastError` and `lastAttemptAt` so `whatsapp-sched --status` can show why it is still pending.

## Queue Model

Queue files are JSON arrays. Each item is one message job:

```json
[
  {
    "recipient": "Mike Smith",
    "message": "Hello *Mike*",
    "attachments": ["C:\\path\\file.pdf"],
    "shutdown": false
  }
]
```

Recipients that should send by phone include an optional `phone` field:

```json
[
  {
    "recipient": "Jane Doe",
    "phone": "15551234567",
    "message": "Hello Jane",
    "attachments": [],
    "shutdown": false
  }
]
```

Successful items are removed from the queue. Blank-message items are removed before sending starts. Generated multi-recipient queues place `shutdown: true` only on the final item.

## Scheduling

Scheduled tasks are named with unique timestamps:

```text
WhatsAppQueueSend-20260525-090000-1234
```

Each scheduled send gets its own queue file and task name, so multiple future send times can coexist.

If the requested time has already passed for the current day, the task is scheduled for the following day.

The task is configured for the current interactive Windows user. The computer must be on, awake, logged in, and connected at send time. The tool does not rely on waking from shutdown, sleep, or hibernate.

## Authentication And Security

Authentication is local:

```powershell
whatsapp-sched --auth
```

The user scans a WhatsApp Web QR code once. The saved session is stored in:

```text
.wwebjs_auth/
```

That folder contains active WhatsApp Web session material. Do not share it, upload it, or sync it to cloud storage.

The run lock exists partly to protect this auth profile. Multiple Chromium sessions using the same auth directory can conflict, so only one scheduled send run is allowed at a time.

Locks older than 30 minutes are treated as stale and removed automatically.

## Recipient Resolution

Recipients are resolved in this order:

1. Existing WhatsApp chats by scored fuzzy name matching.
2. WhatsApp contacts by name, push name, short name, or number.
3. Phone-number lookup through WhatsApp if a `phone` mapping exists.

The matching logic scores candidates instead of blindly picking the first substring match:

```text
exact match
prefix match
whole-word match
inner substring match
loose substring match
```

If multiple candidates tie with the same best score, the send fails instead of guessing.

Logs include the exact match:

```text
Matched "Mike" to WhatsApp chat "Mike Smith".
```

## Messages And Attachments

The TUI supports:

- one-line message input
- clipboard input with `clip`
- multi-line sentinel input with `<<<` and `>>>`

The TUI and CLI convert simple Markdown-style formatting:

```text
**bold** -> *bold*
__italic__ -> _italic_
```

Attachments are full file paths. The TUI and CLI validate paths before scheduling. If an attachment is missing at send time, the sender logs the missing file and skips that attachment. The text message can still send.

## Status And Dry Run

Status:

```powershell
whatsapp-sched --status
whatsapp-sched --list
```

Status shows:

- active run lock
- pending queue files
- first pending recipient
- last queue error
- scheduled WhatsApp tasks

Dry run:

```powershell
whatsapp-sched --dry-run
```

Dry-run starts WhatsApp Web, uses saved auth, resolves recipients, and validates attachment paths without sending messages, removing queue items, or triggering shutdown.

## Shutdown

If shutdown is enabled, generated multi-recipient queues put `shutdown: true` only on the final item.

After that item sends successfully, the sender schedules:

```powershell
shutdown /s /t 120
```

The two-minute delay can be canceled with:

```powershell
shutdown /a
```

## Reliability Constraints

This is not an official WhatsApp API integration. It depends on:

- WhatsApp Web
- `whatsapp-web.js`
- Puppeteer/Chromium
- Windows Task Scheduler
- the local saved auth session

If WhatsApp Web changes, the library may need updates.

For scheduled sends, the machine should remain awake. For overnight use:

- desktops can leave the monitor off
- laptops should be plugged in
- sleep and hibernate should be disabled
- laptop lid close should be set to `Do nothing`, or the lid should remain open
- the built-in shutdown option can power off the computer after sending

## Design Guardrails

- Keep the project scheduler-first.
- Avoid hosted services and cloud dependencies.
- Avoid a database until JSON queues become a real limitation.
- Keep dry-run as the safety path for risky changes.
- Do not make automated tests send real WhatsApp messages.
- Keep bot-like features optional, local, and separate from the core scheduler.
