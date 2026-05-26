# WhatsApp Scheduled Messenger

Local Windows tool for scheduling WhatsApp messages with optional file attachments.

You fill out a quick terminal prompt, pick a send time, and Windows Task Scheduler runs the send later using your saved WhatsApp Web session.

## Requirements

- Windows
- Node.js installed
- PowerShell
- A WhatsApp account that can use WhatsApp Web

## Install

Install globally with npm:

```powershell
npm install -g whatsapp-scheduler
```

That gives you the `whatsapp-sched` command from any terminal folder.

For local development from this project folder:

```powershell
cd C:\tools\whatsapp-scheduler
npm install
npm link
```

`npm link` makes your local checkout available as `whatsapp-sched`.

## First-Time WhatsApp Auth

Run this once:

```powershell
whatsapp-sched --auth
```

Scan the QR code with WhatsApp on your phone. The saved login session is stored in:

```text
.wwebjs_auth
```

Do not delete `.wwebjs_auth` unless you want to re-authenticate. Do not share it, upload it, or sync it to cloud storage; it contains the saved WhatsApp Web session.

## Normal Use

After install and auth, the usual workflow is just:

```powershell
whatsapp-sched
```

The TUI asks for:

- number of recipients
- whether any recipients are missing from your WhatsApp chats
- phone numbers only for people missing from chats, if needed
- all recipient names, including any phone-only people
- message
- attachment paths
- send time
- whether to shut down after sending

Then it writes a queue file under `queues\` and creates a one-time Windows scheduled task.

Recipient names are still entered for everyone. The sender first searches existing WhatsApp chats by name. Phone mappings are only for recipients who do not already have a chat, and those mapped names must also appear in the final recipient list.

For long messages in the TUI, the easiest path is: copy the message, type `clip` at the message prompt, then press Enter. The TUI will read the clipboard.

For manual multi-line entry, start with `<<<` and end with `>>>`. These also work on the same line, for example `<<<hello>>>`.

## Fast CLI Use

Send one message later:

```powershell
whatsapp-sched 09:00 "Mike Smith" "Hey there!"
```

Multiple recipients:

```powershell
whatsapp-sched 09:00 "Mike Smith, Jane Doe" "Hey **team**"
```

Attach a file:

```powershell
whatsapp-sched 09:00 "Mike Smith" "Here is the file" --file "C:\path\file.pdf"
```

Attachment paths are validated before scheduling. If a file is missing, the TUI/CLI stops and shows the missing path before creating the scheduled task.

The TUI accepts normal quoted paths and also cleans up accidental pasted `cd "C:\path\file.txt"` input.

New contact by phone number:

```powershell
whatsapp-sched 21:30 "Jane Doe" "New contact test" --phone "Jane Doe=15551234567"
```

Shut down after all messages send:

```powershell
whatsapp-sched 23:00 "Mike Smith" "Done for the night" --shutdown
```

For generated multi-recipient queues, shutdown is only placed on the final queue item. The sender still honors `shutdown: true` on any manually edited queue item, but shutdown only runs after that item has sent successfully.

Show current queues, run lock, and scheduled WhatsApp tasks:

```powershell
whatsapp-sched --status
```

`--list` is an alias for `--status`.

Completed empty queue files are hidden from the main status list. If a queued send fails, status shows the pending recipient plus the last recorded error from the sender.

## Real WhatsApp Dry Run

To test WhatsApp startup, saved auth, recipient resolution, and attachment paths without sending anything:

```powershell
whatsapp-sched --dry-run
```

Dry-run uses the newest pending queue file automatically and exits without sending messages, removing queue items, or shutting down.

Accepted time formats:

```text
4:38
04:38
21:30
```

Times use 24-hour format.

## Message Formatting

WhatsApp formatting is used at send time:

```text
*bold*
_italic_
```

The TUI and CLI also convert simple Markdown-style formatting:

```text
**bold** -> *bold*
__italic__ -> _italic_
```

## How It Works

The TUI/CLI writes a queue file, Windows Task Scheduler runs it later, and the sender uses WhatsApp Web with your saved local auth session.

## Logs

If a message does not send, check status first:

```powershell
whatsapp-sched --status
```

Logs are written under:

```text
logs\
```

## Cancel A Scheduled Send

Use the exact task name printed after scheduling:

```powershell
schtasks /delete /tn WhatsAppQueueSend-20260525-090000-1234 /f
```

Older legacy tasks may still be named `WhatsAppQueueSend`.

## Contributing

Development notes, queue format, dry-run testing, logs, locks, and test commands are in `CONTRIBUTING.md`.
