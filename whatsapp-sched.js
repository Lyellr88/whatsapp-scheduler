#!/usr/bin/env node

const { spawnSync } = require('child_process');
const fs = require('fs');
const path = require('path');
const { normalizePhone } = require('./lib/phone');
const { normalizeName } = require('./lib/matching');

const PROJECT_DIR = __dirname;
const QUEUE_DIR = path.join(PROJECT_DIR, 'queues');
const LEGACY_QUEUE_FILE = path.join(PROJECT_DIR, 'queue.json');
const LOCK_DIR = path.join(PROJECT_DIR, '.run.lock');
const SETUP_SCRIPT = path.join(PROJECT_DIR, 'setup_send.ps1');
const SCHEDULE_SCRIPT = path.join(PROJECT_DIR, 'schedule_send.ps1');
const SEND_SCRIPT = process.env.WHATSAPP_SCHED_SENDER || path.join(PROJECT_DIR, 'send_whatsapp.js');
const SCHTASKS_COMMAND = process.env.WHATSAPP_SCHED_SCHTASKS || 'schtasks';

function usage(exitCode = 0) {
    const out = exitCode === 0 ? console.log : console.error;
    out(`Usage:
  whatsapp-sched
      Open the interactive setup.

  whatsapp-sched <time> <recipients> <message> [options]
      Build a queue file and schedule a send.

  whatsapp-sched --dry-run [queue-file]
      Test WhatsApp auth, recipient matching, and attachments without sending.

  whatsapp-sched --auth
      Authenticate WhatsApp Web and save the local session.

Examples:
  whatsapp-sched 09:00 "Mike Smith" "Hey there!"
  whatsapp-sched 4:38 "Mike Smith, Jane Doe" "Hey **team**" --file "C:\\path\\doc.pdf"
  whatsapp-sched 21:30 "Jane Doe" "New contact test" --phone "Jane Doe=15551234567"
  whatsapp-sched --dry-run

Options:
  --file, -f <path>       Add an attachment. Can be repeated or comma-separated.
  --phone, -p <name=num>  Add phone mapping for a recipient not in chats. Can be repeated.
  --shutdown             Shut down after all queued messages send.
  --no-schedule          Write queue file but do not create the scheduled task.
  --dry-run [queue-file] Resolve newest pending queue, or a specific queue, without sending.
  --auth                 Scan WhatsApp Web QR and save the local session.
  --status, --list       Show pending queue files and WhatsApp scheduled tasks.
  --help, -h             Show this help.
`);
    process.exit(exitCode);
}

function normalizeTime(value) {
    const match = /^(\d{1,2}):(\d{2})$/.exec(value || '');
    if (!match) {
        throw new Error('Invalid time format. Use H:MM or HH:MM, e.g. 4:38 or 21:30.');
    }

    const hour = Number(match[1]);
    const minute = Number(match[2]);
    if (hour < 0 || hour > 23 || minute < 0 || minute > 59) {
        throw new Error('Invalid time. Use 0:00 through 23:59.');
    }

    return `${String(hour).padStart(2, '0')}:${String(minute).padStart(2, '0')}`;
}

function splitCommaList(value) {
    if (!value) {
        return [];
    }

    return value
        .split(',')
        .map(item => item.trim().replace(/^["']|["']$/g, ''))
        .filter(Boolean);
}

function convertToWhatsAppText(value) {
    return value
        .replace(/\*\*(.+?)\*\*/g, '*$1*')
        .replace(/__(.+?)__/g, '_$1_');
}

function runPowerShell(script, args) {
    const result = spawnSync(
        'powershell.exe',
        ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', script, ...args],
        { cwd: PROJECT_DIR, stdio: 'inherit' }
    );

    if (result.error) {
        throw result.error;
    }

    process.exitCode = result.status || 0;
    return process.exitCode;
}

function runNode(script, args) {
    const result = spawnSync(process.execPath, [script, ...args], {
        cwd: PROJECT_DIR,
        encoding: 'utf8',
        env: process.env
    });

    if (result.error) {
        throw result.error;
    }

    if (result.stdout) {
        process.stdout.write(result.stdout);
    }
    if (result.stderr) {
        process.stderr.write(result.stderr);
    }

    process.exitCode = result.status || 0;
    return process.exitCode;
}

function readQueueFileSummary(filePath) {
    try {
        const raw = fs.readFileSync(filePath, 'utf8').replace(/^\uFEFF/, '');
        const parsed = JSON.parse(raw);
        const items = Array.isArray(parsed) ? parsed : [parsed];
        const pending = items.filter(item => item && typeof item.message === 'string' && item.message.trim() !== '');
        const firstRecipient = pending[0] ? (pending[0].recipient || pending[0].phone || pending[0].number || '(no recipient)') : '(empty)';
        const firstError = pending[0] && pending[0].lastError ? pending[0].lastError : null;
        const firstAttemptAt = pending[0] && pending[0].lastAttemptAt ? pending[0].lastAttemptAt : null;
        return {
            ok: true,
            total: items.length,
            pending: pending.length,
            firstRecipient,
            firstError,
            firstAttemptAt
        };
    } catch (err) {
        return {
            ok: false,
            error: err.message
        };
    }
}

function parseScheduledTasks(output) {
    const tasks = [];
    let current = {};

    for (const line of output.split(/\r?\n/)) {
        const trimmed = line.trim();
        if (!trimmed) {
            if (current.TaskName) {
                tasks.push(current);
                current = {};
            }
            continue;
        }

        const match = /^([^:]+):\s*(.*)$/.exec(trimmed);
        if (match) {
            current[match[1].trim()] = match[2].trim();
        }
    }

    if (current.TaskName) {
        tasks.push(current);
    }

    return tasks.filter(task => task.TaskName && task.TaskName.includes('WhatsAppQueueSend'));
}

function listScheduledTasks() {
    const result = spawnSync(SCHTASKS_COMMAND, ['/query', '/fo', 'LIST', '/v'], {
        cwd: PROJECT_DIR,
        encoding: 'utf8'
    });

    if (result.error) {
        return { ok: false, error: result.error.message, tasks: [] };
    }

    const output = `${result.stdout || ''}\n${result.stderr || ''}`;
    return {
        ok: result.status === 0,
        error: result.status === 0 ? null : output.trim(),
        tasks: parseScheduledTasks(output)
    };
}

function printStatus() {
    console.log('WhatsApp Scheduled Messenger Status');
    console.log(`Project: ${PROJECT_DIR}`);
    console.log('');

    if (fs.existsSync(LOCK_DIR)) {
        console.log('Run lock: active');
        const ownerPath = path.join(LOCK_DIR, 'owner.txt');
        if (fs.existsSync(ownerPath)) {
            for (const line of fs.readFileSync(ownerPath, 'utf8').split(/\r?\n/).filter(Boolean)) {
                console.log(`  ${line}`);
            }
        }
    } else {
        console.log('Run lock: none');
    }

    console.log('');
    console.log('Queue files:');
    const queueFiles = fs.existsSync(QUEUE_DIR)
        ? fs.readdirSync(QUEUE_DIR)
            .filter(name => name.toLowerCase().endsWith('.json'))
            .map(name => path.join(QUEUE_DIR, name))
            .sort()
        : [];

    if (queueFiles.length === 0) {
        console.log('  (none)');
    } else {
        let completedCount = 0;
        let printedCount = 0;
        for (const filePath of queueFiles) {
            const summary = readQueueFileSummary(filePath);
            const name = path.basename(filePath);
            if (summary.ok) {
                if (summary.pending === 0) {
                    completedCount++;
                    continue;
                }
                printedCount++;
                console.log(`  ${name}: ${summary.pending}/${summary.total} pending, first: ${summary.firstRecipient}`);
                if (summary.firstError) {
                    console.log(`    Last error: ${summary.firstError}`);
                    if (summary.firstAttemptAt) {
                        console.log(`    Last attempt: ${summary.firstAttemptAt}`);
                    }
                }
            } else {
                printedCount++;
                console.log(`  ${name}: invalid JSON (${summary.error})`);
            }
        }
        if (printedCount === 0) {
            console.log('  (none pending)');
        }
        if (completedCount > 0) {
            console.log(`  (${completedCount} completed empty queue file${completedCount === 1 ? '' : 's'} hidden)`);
        }
    }

    if (fs.existsSync(LEGACY_QUEUE_FILE)) {
        const summary = readQueueFileSummary(LEGACY_QUEUE_FILE);
        if (summary.ok && summary.pending > 0) {
            console.log(`  legacy queue.json: ${summary.pending}/${summary.total} pending, first: ${summary.firstRecipient}`);
        }
    }

    console.log('');
    console.log('Scheduled tasks:');
    const scheduled = listScheduledTasks();
    if (!scheduled.ok && scheduled.tasks.length === 0) {
        console.log(`  Could not query tasks: ${scheduled.error || 'unknown error'}`);
    } else if (scheduled.tasks.length === 0) {
        console.log('  (none)');
    } else {
        for (const task of scheduled.tasks) {
            console.log(`  ${task.TaskName}`);
            console.log(`    Next Run Time: ${task['Next Run Time'] || 'N/A'}`);
            console.log(`    Status: ${task.Status || 'N/A'}`);
            if (task['Task To Run']) {
                console.log(`    Task To Run: ${task['Task To Run']}`);
            }
        }
    }
}

function listPendingQueueFiles() {
    if (!fs.existsSync(QUEUE_DIR)) {
        return [];
    }

    return fs.readdirSync(QUEUE_DIR)
        .filter(name => name.toLowerCase().endsWith('.json'))
        .map(name => path.join(QUEUE_DIR, name))
        .map(filePath => ({
            filePath,
            summary: readQueueFileSummary(filePath),
            mtimeMs: fs.statSync(filePath).mtimeMs
        }))
        .filter(entry => entry.summary.ok && entry.summary.pending > 0)
        .sort((a, b) => b.mtimeMs - a.mtimeMs)
        .map(entry => entry.filePath);
}

function resolveDryRunQueueFile(argv) {
    const dryRunIndex = argv.indexOf('--dry-run');
    if (dryRunIndex === -1) {
        return null;
    }

    const remaining = argv.filter((_, index) => index !== dryRunIndex);
    if (remaining.length > 1) {
        throw new Error('Use: whatsapp-sched --dry-run [queue-file]');
    }

    if (remaining.length === 1) {
        const queueFile = path.resolve(process.cwd(), remaining[0]);
        if (!fs.existsSync(queueFile)) {
            throw new Error(`Dry-run queue file not found: ${queueFile}`);
        }
        return queueFile;
    }

    const pending = listPendingQueueFiles();
    if (pending.length === 0) {
        throw new Error('No pending queue files found. Create one first with whatsapp-sched ... --no-schedule or run the TUI.');
    }

    return pending[0];
}

function runDryRun(argv) {
    const queueFile = resolveDryRunQueueFile(argv);
    if (!queueFile) {
        return false;
    }

    console.log(`Dry-run queue: ${queueFile}`);
    process.exit(runNode(SEND_SCRIPT, ['--dry-run', '--from-queue', '--queue-file', queueFile]));
}

function runAuth(argv) {
    if (!argv.includes('--auth')) {
        return false;
    }

    if (argv.length !== 1) {
        throw new Error('Use: whatsapp-sched --auth');
    }

    process.exit(runNode(SEND_SCRIPT, ['--auth-only']));
}

function parseArgs(argv) {
    if (argv.includes('--help') || argv.includes('-h')) {
        usage(0);
    }

    if (argv.includes('--status') || argv.includes('--list')) {
        printStatus();
        process.exit(0);
    }

    const positional = [];
    const files = [];
    const phoneMappings = [];
    let shutdown = false;
    let noSchedule = false;

    for (let i = 0; i < argv.length; i++) {
        const arg = argv[i];

        if (arg === '--shutdown') {
            shutdown = true;
        } else if (arg === '--no-schedule') {
            noSchedule = true;
        } else if (arg === '--file' || arg === '-f') {
            const value = argv[++i];
            if (!value) {
                throw new Error(`${arg} requires a file path.`);
            }
            files.push(...splitCommaList(value));
        } else if (arg === '--phone' || arg === '-p') {
            const value = argv[++i];
            if (!value) {
                throw new Error(`${arg} requires a name=number mapping.`);
            }
            phoneMappings.push(...splitCommaList(value));
        } else if (arg.startsWith('-')) {
            throw new Error(`Unknown option: ${arg}`);
        } else {
            positional.push(arg);
        }
    }

    if (positional.length !== 3) {
        usage(1);
    }

    return {
        time: normalizeTime(positional[0]),
        recipients: splitCommaList(positional[1]),
        message: convertToWhatsAppText(positional[2]),
        files,
        phoneMappings,
        shutdown,
        noSchedule
    };
}

function buildPhoneMap(recipients, mappings) {
    const phoneMap = new Map();
    const recipientByKey = new Map(recipients.map(name => [normalizeName(name), name]));

    for (const mapping of mappings) {
        const parts = mapping.split('=');
        if (parts.length < 2) {
            throw new Error(`Invalid phone mapping "${mapping}". Use name=number.`);
        }

        const rawName = parts.shift().trim();
        const phone = normalizePhone(parts.join('=').trim());
        const recipient = recipientByKey.get(normalizeName(rawName));
        if (!recipient) {
            throw new Error(`Phone mapping name "${rawName}" is not in the recipient list.`);
        }
        if (!phone) {
            throw new Error(`Phone mapping for "${rawName}" is too short after normalization.`);
        }

        phoneMap.set(recipient, phone);
    }

    return phoneMap;
}

function findSimilarFiles(filePath) {
    const directory = path.dirname(filePath);
    const targetName = path.basename(filePath).toLowerCase();

    if (!directory || !fs.existsSync(directory)) {
        return [];
    }

    try {
        return fs.readdirSync(directory)
            .filter(name => {
                const lower = name.toLowerCase();
                return lower.includes(targetName.slice(0, 4)) || targetName.includes(lower.slice(0, 4));
            })
            .slice(0, 5)
            .map(name => path.join(directory, name));
    } catch {
        return [];
    }
}

function validateAttachments(files) {
    const missing = files.filter(filePath => !fs.existsSync(filePath));
    if (missing.length === 0) {
        return;
    }

    const lines = ['Attachment validation failed. These files do not exist:'];
    for (const filePath of missing) {
        lines.push(`  - ${filePath}`);
        const suggestions = findSimilarFiles(filePath);
        if (suggestions.length > 0) {
            lines.push('    Similar files in that folder:');
            suggestions.forEach(suggestion => lines.push(`      ${suggestion}`));
        }
    }

    lines.push('Fix the path or remove the --file option, then run the command again.');
    throw new Error(lines.join('\n'));
}

function writeQueue(options) {
    if (options.recipients.length === 0) {
        throw new Error('At least one recipient is required.');
    }
    if (!options.message.trim()) {
        throw new Error('Message cannot be blank.');
    }

    const phoneMap = buildPhoneMap(options.recipients, options.phoneMappings);
    validateAttachments(options.files);
    fs.mkdirSync(QUEUE_DIR, { recursive: true });
    const queue = options.recipients.map((recipient, index) => {
        const item = {
            recipient,
            message: options.message,
            attachments: options.files,
            shutdown: options.shutdown && index === options.recipients.length - 1
        };

        if (phoneMap.has(recipient)) {
            item.phone = phoneMap.get(recipient);
        }

        return item;
    });

    const stamp = new Date().toISOString().replace(/\D/g, '').slice(0, 14);
    const queueFile = path.join(QUEUE_DIR, `queue-${stamp}.json`);
    fs.writeFileSync(queueFile, `${JSON.stringify(queue, null, 2)}\n`);
    console.log(`Queue saved: ${queueFile}`);
    console.log(`Recipients: ${queue.length}`);
    console.log(`Files: ${options.files.length}`);
    console.log(`Shutdown: ${options.shutdown}`);
    return queueFile;
}

try {
    const argv = process.argv.slice(2);
    if (argv.length === 0) {
        process.exit(runPowerShell(SETUP_SCRIPT, []));
    }

    if (runAuth(argv) !== false) {
        process.exit(process.exitCode || 0);
    }

    if (runDryRun(argv) !== false) {
        process.exit(process.exitCode || 0);
    }

    const options = parseArgs(argv);
    const queueFile = writeQueue(options);

    if (options.noSchedule) {
        console.log('NoSchedule enabled. Task was not scheduled.');
        process.exit(0);
    }

    process.exit(runPowerShell(SCHEDULE_SCRIPT, [options.time, '-QueueFile', queueFile]));
} catch (err) {
    console.error(`Error: ${err.message}`);
    process.exit(1);
}
