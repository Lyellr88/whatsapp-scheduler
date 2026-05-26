const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { spawnSync } = require('child_process');

const repoRoot = path.resolve(__dirname, '..');
const sender = path.join(repoRoot, 'send_whatsapp.js');

function makeTempDir() {
    return fs.mkdtempSync(path.join(os.tmpdir(), 'whatsapp-dry-run-test-'));
}

function runSender(args, env = {}) {
    return spawnSync(process.execPath, [sender, ...args], {
        cwd: repoRoot,
        encoding: 'utf8',
        env: {
            ...process.env,
            WHATSAPP_SCHED_FAKE_CLIENT: '1',
            ...env
        }
    });
}

test('dry-run from queue resolves recipient and leaves queue file unchanged', () => {
    const dir = makeTempDir();
    const attachment = path.join(dir, 'report with spaces.txt');
    const queueFile = path.join(dir, 'queue.json');
    fs.writeFileSync(attachment, 'fixture');

    const queue = [
        {
            recipient: 'Mike Smith',
            message: 'Hello',
            attachments: [attachment],
            shutdown: true
        }
    ];
    fs.writeFileSync(queueFile, `${JSON.stringify(queue, null, 2)}\n`);
    const before = fs.readFileSync(queueFile, 'utf8');

    const result = runSender(['--dry-run', '--from-queue', '--queue-file', queueFile]);

    assert.equal(result.status, 0, result.stderr);
    assert.match(result.stdout, /WhatsApp client ready/);
    assert.match(result.stdout, /Matched "Mike Smith" to WhatsApp chat "Mike Smith"/);
    assert.match(result.stdout, /\[dry-run\] Recipient resolves to: Mike Smith/);
    assert.match(result.stdout, /\[dry-run\] Attachment exists:/);
    assert.match(result.stdout, /Queue validation completed\. Queue file was not changed/);
    assert.equal(fs.readFileSync(queueFile, 'utf8'), before);
});

test('dry-run from queue fails on missing attachment and still leaves queue unchanged', () => {
    const dir = makeTempDir();
    const queueFile = path.join(dir, 'queue.json');
    const missing = path.join(dir, 'missing.txt');

    const queue = [
        {
            recipient: 'Mike Smith',
            message: 'Hello',
            attachments: [missing],
            shutdown: false
        }
    ];
    fs.writeFileSync(queueFile, `${JSON.stringify(queue, null, 2)}\n`);
    const before = fs.readFileSync(queueFile, 'utf8');

    const result = runSender(['--dry-run', '--from-queue', '--queue-file', queueFile]);

    assert.notEqual(result.status, 0);
    assert.match(result.stderr, /\[dry-run\] Attachment not found:/);
    assert.equal(fs.readFileSync(queueFile, 'utf8'), before);
});

test('direct dry-run resolves phone without sending', () => {
    const result = runSender(['--dry-run', '15551234567', 'Hello by phone']);

    assert.equal(result.status, 0, result.stderr);
    assert.match(result.stdout, /Matched phone "15551234567" to WhatsApp number "15551234567"/);
    assert.match(result.stdout, /\[dry-run\] Text message would be sent/);
    assert.match(result.stdout, /No WhatsApp message, attachment, queue mutation, or shutdown was performed/);
});
