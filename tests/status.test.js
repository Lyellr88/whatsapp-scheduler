const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');

const { makeTempProject, runCli } = require('./helpers-node');

test('status prints none for empty queues and exits cleanly when task query is unavailable', () => {
    const projectDir = makeTempProject();
    const result = runCli(projectDir, ['--status']);

    assert.equal(result.status, 0, result.stderr);
    assert.match(result.stdout, /Queue files:\r?\n  \(none\)/);
    assert.match(result.stdout, /Scheduled tasks:\r?\n  (Could not query tasks:|\(none\)|\\?WhatsAppQueueSend)/);
});

test('status reports pending count and first recipient for queue files', () => {
    const projectDir = makeTempProject();
    const queueDir = path.join(projectDir, 'queues');
    fs.mkdirSync(queueDir);
    fs.writeFileSync(path.join(queueDir, 'queue-test.json'), JSON.stringify([
        { recipient: 'Jane Doe', message: 'Hello' },
        { recipient: 'Mike Smith', message: '' }
    ]));

    const result = runCli(projectDir, ['--status']);

    assert.equal(result.status, 0, result.stderr);
    assert.match(result.stdout, /queue-test\.json: 1\/2 pending, first: Jane Doe/);
});

test('status hides completed empty queue files but reports pending failures', () => {
    const projectDir = makeTempProject();
    const queueDir = path.join(projectDir, 'queues');
    fs.mkdirSync(queueDir);
    fs.writeFileSync(path.join(queueDir, 'queue-empty.json'), '[]');
    fs.writeFileSync(path.join(queueDir, 'queue-failed.json'), JSON.stringify([
        {
            recipient: 'Mike',
            message: 'Hello',
            lastError: 'Could not resolve recipient "Mike".',
            lastAttemptAt: '2026-05-25T12:00:00.000Z'
        }
    ]));

    const result = runCli(projectDir, ['--status']);

    assert.equal(result.status, 0, result.stderr);
    assert.doesNotMatch(result.stdout, /queue-empty\.json: 0\/0 pending/);
    assert.match(result.stdout, /1 completed empty queue file hidden/);
    assert.match(result.stdout, /queue-failed\.json: 1\/1 pending, first: Mike/);
    assert.match(result.stdout, /Last error: Could not resolve recipient "Mike"\./);
    assert.match(result.stdout, /Last attempt: 2026-05-25T12:00:00\.000Z/);
});

test('status reports invalid queue JSON without failing the command', () => {
    const projectDir = makeTempProject();
    const queueDir = path.join(projectDir, 'queues');
    fs.mkdirSync(queueDir);
    fs.writeFileSync(path.join(queueDir, 'bad.json'), '{not json');

    const result = runCli(projectDir, ['--status']);

    assert.equal(result.status, 0, result.stderr);
    assert.match(result.stdout, /bad\.json: invalid JSON/);
});

test('status reports non-empty legacy queue but omits empty legacy queue', () => {
    const projectDir = makeTempProject();

    fs.writeFileSync(path.join(projectDir, 'queue.json'), JSON.stringify([{ recipient: 'Legacy User', message: 'Pending' }]));
    let result = runCli(projectDir, ['--status']);
    assert.equal(result.status, 0, result.stderr);
    assert.match(result.stdout, /legacy queue\.json: 1\/1 pending, first: Legacy User/);

    fs.writeFileSync(path.join(projectDir, 'queue.json'), '[]');
    result = runCli(projectDir, ['--status']);
    assert.equal(result.status, 0, result.stderr);
    assert.doesNotMatch(result.stdout, /legacy queue\.json/);
});

test('status reports active run lock owner details', () => {
    const projectDir = makeTempProject();
    const lockDir = path.join(projectDir, '.run.lock');
    fs.mkdirSync(lockDir);
    fs.writeFileSync(path.join(lockDir, 'owner.txt'), 'pid=1234\r\nqueue=queue-test.json\r\n');

    const result = runCli(projectDir, ['--status']);

    assert.equal(result.status, 0, result.stderr);
    assert.match(result.stdout, /Run lock: active/);
    assert.match(result.stdout, /pid=1234/);
    assert.match(result.stdout, /queue=queue-test\.json/);
});

test('--list is an alias for --status', () => {
    const projectDir = makeTempProject();
    const result = runCli(projectDir, ['--list']);

    assert.equal(result.status, 0, result.stderr);
    assert.match(result.stdout, /WhatsApp Scheduled Messenger Status/);
    assert.match(result.stdout, /Queue files:/);
    assert.match(result.stdout, /Scheduled tasks:/);
});
