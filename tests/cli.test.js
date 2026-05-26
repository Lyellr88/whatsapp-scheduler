const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');

const { makeTempProject, readQueues, repoRoot, runCli } = require('./helpers-node');

test('CLI writes one queue item with --no-schedule and does not invoke scheduler', () => {
    const projectDir = makeTempProject();
    const result = runCli(projectDir, ['09:00', 'Mike Smith', 'Hello', '--no-schedule']);

    assert.equal(result.status, 0, result.stderr);
    assert.match(result.stdout, /NoSchedule enabled/);

    const queues = readQueues(projectDir);
    assert.equal(queues.length, 1);
    assert.equal(queues[0].raw.charCodeAt(0) === 0xFEFF, false);
    assert.deepEqual(queues[0].items, [{
        recipient: 'Mike Smith',
        message: 'Hello',
        attachments: [],
        shutdown: false
    }]);
});

test('CLI preserves multiple recipients and puts shutdown only on the last item', () => {
    const projectDir = makeTempProject();
    const result = runCli(projectDir, ['21:30', 'Mike Smith, Jane Doe, Ann Marie', 'Hello team', '--shutdown', '--no-schedule']);

    assert.equal(result.status, 0, result.stderr);
    const [queue] = readQueues(projectDir);

    assert.deepEqual(queue.items.map(item => item.recipient), ['Mike Smith', 'Jane Doe', 'Ann Marie']);
    assert.deepEqual(queue.items.map(item => item.message), ['Hello team', 'Hello team', 'Hello team']);
    assert.deepEqual(queue.items.map(item => item.shutdown), [false, false, true]);
});

test('CLI normalizes markdown and phone mappings', () => {
    const projectDir = makeTempProject();
    const result = runCli(projectDir, [
        '9:05',
        'Jane Doe',
        'Use **bold** and __italic__',
        '--phone',
        'Jane Doe=5551234567',
        '--no-schedule'
    ]);

    assert.equal(result.status, 0, result.stderr);
    const [queue] = readQueues(projectDir);

    assert.equal(queue.items[0].message, 'Use *bold* and _italic_');
    assert.equal(queue.items[0].phone, '15551234567');
});

test('CLI phone mapping matches recipient names after punctuation and spacing normalization', () => {
    const projectDir = makeTempProject();
    const result = runCli(projectDir, [
        '9:05',
        'Jane   Doe',
        'Hello',
        '--phone',
        'jane-doe=+1 (555) 123-4567',
        '--no-schedule'
    ]);

    assert.equal(result.status, 0, result.stderr);
    const [queue] = readQueues(projectDir);

    assert.equal(queue.items[0].recipient, 'Jane   Doe');
    assert.equal(queue.items[0].phone, '15551234567');
});

test('CLI writes valid attachment paths into every queue item', () => {
    const projectDir = makeTempProject();
    const attachment = path.join(projectDir, 'file with spaces.txt');
    fs.writeFileSync(attachment, 'attachment');

    const result = runCli(projectDir, ['09:00', 'Mike Smith, Jane Doe', 'See attached', '--file', attachment, '--no-schedule']);

    assert.equal(result.status, 0, result.stderr);
    const [queue] = readQueues(projectDir);
    assert.deepEqual(queue.items.map(item => item.attachments), [[attachment], [attachment]]);
});

test('CLI rejects invalid time and creates no queue file', () => {
    const projectDir = makeTempProject();
    const result = runCli(projectDir, ['24:00', 'Mike Smith', 'Hello', '--no-schedule']);

    assert.notEqual(result.status, 0);
    assert.match(result.stderr, /Invalid time/);
    assert.equal(readQueues(projectDir).length, 0);
});

test('CLI rejects non-padded minute and creates no queue file', () => {
    const projectDir = makeTempProject();
    const result = runCli(projectDir, ['9:5', 'Mike Smith', 'Hello', '--no-schedule']);

    assert.notEqual(result.status, 0);
    assert.match(result.stderr, /Invalid time format/);
    assert.equal(readQueues(projectDir).length, 0);
});

test('CLI rejects phone mapping names outside the recipient list before queue creation', () => {
    const projectDir = makeTempProject();
    const result = runCli(projectDir, ['09:00', 'Jane Doe', 'Hello', '--phone', 'Mike Smith=5551234567', '--no-schedule']);

    assert.notEqual(result.status, 0);
    assert.match(result.stderr, /not in the recipient list/);
    assert.equal(readQueues(projectDir).length, 0);
});

test('CLI rejects too-short phone mappings before queue creation', () => {
    const projectDir = makeTempProject();
    const result = runCli(projectDir, ['09:00', 'Jane Doe', 'Hello', '--phone', 'Jane Doe=555', '--no-schedule']);

    assert.notEqual(result.status, 0);
    assert.match(result.stderr, /too short/);
    assert.equal(readQueues(projectDir).length, 0);
});

test('CLI rejects missing attachments and prints the failed path before queue creation', () => {
    const projectDir = makeTempProject();
    const missing = path.join(projectDir, 'missing.pdf');
    const result = runCli(projectDir, ['09:00', 'Mike Smith', 'Hello', '--file', missing, '--no-schedule']);

    assert.notEqual(result.status, 0);
    assert.match(result.stderr, /Attachment validation failed/);
    assert.match(result.stderr, /missing\.pdf/);
    assert.equal(readQueues(projectDir).length, 0);
});

test('CLI dry-run uses newest pending queue by default and leaves it unchanged', () => {
    const projectDir = makeTempProject();
    const queueDir = path.join(projectDir, 'queues');
    fs.mkdirSync(queueDir);

    const oldQueue = path.join(queueDir, 'queue-old.json');
    const newQueue = path.join(queueDir, 'queue-new.json');
    fs.writeFileSync(oldQueue, JSON.stringify([{ recipient: 'Older User', message: 'Old', attachments: [], shutdown: false }], null, 2));
    fs.writeFileSync(newQueue, `${JSON.stringify([{ recipient: 'Mike Smith', message: 'New', attachments: [], shutdown: false }], null, 2)}\n`);
    fs.utimesSync(oldQueue, new Date('2026-05-25T08:00:00Z'), new Date('2026-05-25T08:00:00Z'));
    fs.utimesSync(newQueue, new Date('2026-05-25T09:00:00Z'), new Date('2026-05-25T09:00:00Z'));
    const before = fs.readFileSync(newQueue, 'utf8');

    const result = runCli(projectDir, ['--dry-run'], {
        env: {
            WHATSAPP_SCHED_FAKE_CLIENT: '1',
            WHATSAPP_SCHED_SENDER: path.join(repoRoot, 'send_whatsapp.js')
        }
    });

    assert.equal(result.status, 0, result.stderr);
    assert.match(result.stdout, /Dry-run queue:/);
    assert.match(result.stdout, /queue-new\.json/);
    assert.match(result.stdout, /\[dry-run\] Recipient resolves to: Mike Smith/);
    assert.equal(fs.readFileSync(newQueue, 'utf8'), before);
});

test('CLI dry-run accepts an explicit queue file', () => {
    const projectDir = makeTempProject();
    const queueDir = path.join(projectDir, 'queues');
    fs.mkdirSync(queueDir);

    const queueFile = path.join(queueDir, 'specific.json');
    fs.writeFileSync(queueFile, `${JSON.stringify([{ recipient: 'Mike Smith', message: 'Specific', attachments: [], shutdown: false }], null, 2)}\n`);

    const result = runCli(projectDir, ['--dry-run', queueFile], {
        env: {
            WHATSAPP_SCHED_FAKE_CLIENT: '1',
            WHATSAPP_SCHED_SENDER: path.join(repoRoot, 'send_whatsapp.js')
        }
    });

    assert.equal(result.status, 0, result.stderr);
    assert.match(result.stdout, /specific\.json/);
    assert.match(result.stdout, /Queue validation completed\. Queue file was not changed/);
});

test('CLI dry-run fails clearly when no pending queue exists', () => {
    const projectDir = makeTempProject();
    const result = runCli(projectDir, ['--dry-run'], {
        env: {
            WHATSAPP_SCHED_FAKE_CLIENT: '1',
            WHATSAPP_SCHED_SENDER: path.join(repoRoot, 'send_whatsapp.js')
        }
    });

    assert.notEqual(result.status, 0);
    assert.match(result.stderr, /No pending queue files found/);
});

test('CLI auth delegates to the sender auth-only mode', () => {
    const projectDir = makeTempProject();
    const fakeSender = path.join(projectDir, 'fake-sender.js');
    fs.writeFileSync(fakeSender, `
        const fs = require('fs');
        fs.writeFileSync(process.env.WHATSAPP_SCHED_AUTH_CAPTURE, process.argv.slice(2).join('\\n'));
    `);
    const capture = path.join(projectDir, 'auth-args.txt');

    const result = runCli(projectDir, ['--auth'], {
        env: {
            WHATSAPP_SCHED_SENDER: fakeSender,
            WHATSAPP_SCHED_AUTH_CAPTURE: capture
        }
    });

    assert.equal(result.status, 0, result.stderr);
    assert.equal(fs.readFileSync(capture, 'utf8'), '--auth-only');
});

test('CLI auth rejects extra arguments', () => {
    const projectDir = makeTempProject();
    const result = runCli(projectDir, ['--auth', 'extra']);

    assert.notEqual(result.status, 0);
    assert.match(result.stderr, /Use: whatsapp-sched --auth/);
});

test('CLI help documents auth mode', () => {
    const projectDir = makeTempProject();
    const result = runCli(projectDir, ['--help']);

    assert.equal(result.status, 0, result.stderr);
    assert.match(result.stdout, /whatsapp-sched --auth/);
    assert.match(result.stdout, /Authenticate WhatsApp Web/);
});
