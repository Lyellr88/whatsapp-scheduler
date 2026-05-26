const { spawnSync } = require('child_process');
const fs = require('fs');
const os = require('os');
const path = require('path');

const repoRoot = path.resolve(__dirname, '..');
const tempProjects = new Set();

process.once('exit', () => {
    for (const projectDir of tempProjects) {
        fs.rmSync(projectDir, { recursive: true, force: true });
    }
});

function makeTempProject() {
    const projectDir = fs.mkdtempSync(path.join(os.tmpdir(), 'whatsapp-sched-test-'));
    tempProjects.add(projectDir);
    fs.copyFileSync(path.join(repoRoot, 'whatsapp-sched.js'), path.join(projectDir, 'whatsapp-sched.js'));
    fs.cpSync(path.join(repoRoot, 'lib'), path.join(projectDir, 'lib'), { recursive: true });
    fs.writeFileSync(path.join(projectDir, 'schedule_send.ps1'), '');
    fs.writeFileSync(path.join(projectDir, 'setup_send.ps1'), '');
    return projectDir;
}

function runCli(projectDir, args, options = {}) {
    return spawnSync(process.execPath, [path.join(projectDir, 'whatsapp-sched.js'), ...args], {
        cwd: projectDir,
        encoding: 'utf8',
        timeout: options.timeout || 10000,
        env: {
            ...process.env,
            ...options.env
        }
    });
}

function readQueues(projectDir) {
    const queueDir = path.join(projectDir, 'queues');
    if (!fs.existsSync(queueDir)) {
        return [];
    }

    return fs.readdirSync(queueDir)
        .filter(name => name.endsWith('.json'))
        .sort()
        .map(name => {
            const filePath = path.join(queueDir, name);
            return {
                name,
                filePath,
                raw: fs.readFileSync(filePath, 'utf8'),
                items: JSON.parse(fs.readFileSync(filePath, 'utf8').replace(/^\uFEFF/, ''))
            };
        });
}

module.exports = {
    makeTempProject,
    readQueues,
    repoRoot,
    runCli
};
