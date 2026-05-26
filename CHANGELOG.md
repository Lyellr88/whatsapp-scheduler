# Changelog

All notable changes to this project are documented here.

## 1.0.0 - 2026-05-25

Initial release of WhatsApp Scheduler as a Windows-first npm CLI.

### Added

- Added `whatsapp-sched` global CLI entrypoint for scheduling WhatsApp messages from any folder.
- Added first-time authentication flow with `whatsapp-sched --auth`.
- Added interactive PowerShell TUI for building scheduled message queues without editing JSON by hand.
- Added fast CLI scheduling for direct command usage.
- Added per-schedule queue files under `queues\` so multiple future send times can coexist.
- Added Windows Task Scheduler integration with unique task names per queued run.
- Added scheduled runner script that logs each run, calls the Node sender, and preserves failed queues.
- Added WhatsApp Web sender using `whatsapp-web.js` and persistent `.wwebjs_auth` sessions.
- Added optional attachments with validation before scheduling.
- Added optional shutdown flag after a completed send batch.
- Added phone-number recipient support for people not already present in WhatsApp chats.
- Added stricter recipient matching with ambiguity detection instead of first-match guessing.
- Added matched-chat logging so users can see exactly which WhatsApp chat/contact was selected.
- Added queue status output with `whatsapp-sched --status` and `whatsapp-sched --list`.
- Added non-invasive real WhatsApp dry-run with `whatsapp-sched --dry-run`.
- Added run lock handling so overlapping scheduled tasks do not launch multiple WhatsApp Web sessions at once.
- Added stale lock detection and cleanup for crashed or abandoned runs.
- Added queue failure metadata with `lastError` and `lastAttemptAt`.
- Added cleanup of completed per-schedule queue files.
- Added Node unit tests for CLI parsing, queue generation, dry-run behavior, matching, phone normalization, and status output.
- Added Pester tests for PowerShell TUI behavior, scheduling validation, runner lock behavior, and integration smoke paths.
- Added ESLint validation for JavaScript files.
- Added PowerShell syntax and PSScriptAnalyzer validation.
- Added `npm run validate` as the broad pre-commit validation command.
- Added npm package metadata, Windows-only install guard, and package file allowlist.
- Added `README.md`, `CONTRIBUTING.md`, MIT `LICENSE`, and this changelog.

### Notes

- Automated tests intentionally do not send real WhatsApp messages.
- Dry-run starts WhatsApp Web, uses saved auth, resolves recipients, validates attachments, and exits without sending.
- Real send and shutdown behavior remain manual smoke-test paths because they touch a live WhatsApp account and the local machine.
- This package is Windows-only because it depends on PowerShell and Windows Task Scheduler.

