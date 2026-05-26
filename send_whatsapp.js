/**
 * send_whatsapp.js
 *
 * Modes:
 *   node send_whatsapp.js --auth-only
 *       First-time setup. Scan QR, save session, exit.
 *
 *   node send_whatsapp.js --from-queue
 *       Read queue.json, send queued messages + attachments, remove each item after it sends.
 *       If any sent queue item has "shutdown": true, shuts down the computer after sending.
 *
 *   node send_whatsapp.js --dry-run --from-queue --queue-file queues\queue-file.json
 *       Start WhatsApp, resolve recipients, validate attachments, and exit without sending.
 *
 *   node send_whatsapp.js "Contact Name" "Your message"
 *       Quick one-off send via CLI args (no attachments).
 */

const { Client, LocalAuth, MessageMedia } = require('whatsapp-web.js');
const qrcode = require('qrcode-terminal');
const { exec } = require('child_process');
const EventEmitter = require('events');
const fs = require('fs');
const path = require('path');
const { normalizePhone } = require('./lib/phone');
const { pickBestNameMatch } = require('./lib/matching');

process.on('unhandledRejection', (err) => {
    console.error('Unhandled promise rejection:', err && err.message ? err.message : err);
});

process.on('uncaughtException', (err) => {
    console.error('Uncaught exception:', err && err.message ? err.message : err);
    process.exit(1);
});

const args = process.argv.slice(2);
const dryRunIndex = args.indexOf('--dry-run');
const dryRun = dryRunIndex !== -1;
if (dryRun) {
    args.splice(dryRunIndex, 1);
}

const queueFileIndex = args.indexOf('--queue-file');
let queueFileArg = null;
if (queueFileIndex !== -1) {
    queueFileArg = args[queueFileIndex + 1];
    if (!queueFileArg) {
        console.error('--queue-file requires a path.');
        process.exit(1);
    }
    args.splice(queueFileIndex, 2);
}

const QUEUE_FILE = queueFileArg ? path.resolve(queueFileArg) : path.join(__dirname, 'queue.json');
const QUEUE_DIR = path.join(__dirname, 'queues');
const authOnly  = args[0] === '--auth-only';
const fromQueue = args[0] === '--from-queue';
const recipientArg = (!authOnly && !fromQueue) ? args[0] : null;
const messageArg   = (!authOnly && !fromQueue) ? args[1] : null;

if (!authOnly && !fromQueue && (!recipientArg || !messageArg)) {
    console.error('Usage:');
    console.error('  node send_whatsapp.js --auth-only');
    console.error('  node send_whatsapp.js --from-queue');
    console.error('  node send_whatsapp.js --dry-run --from-queue --queue-file "queues\\queue-file.json"');
    console.error('  node send_whatsapp.js "Contact Name" "Your message"');
    process.exit(1);
}

function readQueueItems() {
    if (!fs.existsSync(QUEUE_FILE)) {
        console.error('queue.json not found.');
        process.exit(1);
    }

    const rawQueue = fs.readFileSync(QUEUE_FILE, 'utf8').replace(/^\uFEFF/, '');
    const parsed = JSON.parse(rawQueue);
    if (Array.isArray(parsed)) {
        return parsed;
    }

    // Backward compatibility for the original single-message queue format.
    if (parsed && typeof parsed === 'object') {
        return [parsed];
    }

    throw new Error('queue.json must be an array of message objects.');
}

function hasMessage(item) {
    return item && typeof item.message === 'string' && item.message.trim() !== '';
}

function saveQueueItems(items) {
    fs.writeFileSync(QUEUE_FILE, JSON.stringify(items, null, 2));
}

function removeCompletedQueueFileIfSafe() {
    const resolvedQueueFile = path.resolve(QUEUE_FILE);
    const resolvedQueueDir = path.resolve(QUEUE_DIR);
    const fileName = path.basename(resolvedQueueFile).toLowerCase();

    if (path.dirname(resolvedQueueFile) !== resolvedQueueDir || !fileName.startsWith('queue-') || !fileName.endsWith('.json')) {
        return;
    }

    try {
        fs.unlinkSync(resolvedQueueFile);
        console.log(`Completed queue file removed: ${resolvedQueueFile}`);
    } catch (err) {
        console.warn(`Could not remove completed queue file: ${err.message}`);
    }
}

function markFirstQueueItemError(err) {
    if (!fromQueue || !Array.isArray(queueItems) || queueItems.length === 0) {
        return;
    }

    queueItems[0].lastError = err && err.message ? err.message : String(err);
    queueItems[0].lastAttemptAt = new Date().toISOString();
    saveQueueItems(queueItems);
}

async function resolveRecipient(client, recipientName, phone) {
    const searchName = recipientName ? recipientName.trim() : '';
    const chats = await client.getChats();

    if (searchName) {
        const namedChats = chats.filter(c => c.name);
        const chatResult = pickBestNameMatch(searchName, namedChats, c => c.name);

        if (chatResult.ambiguous) {
            console.error(`Ambiguous recipient "${searchName}". Multiple chat matches had the same confidence:`);
            chatResult.tied.slice(0, 10).forEach(match => console.error(`  - ${match.label}`));
            throw new Error(`Recipient "${searchName}" matched multiple chats. Use a more specific name or phone number.`);
        }

        if (chatResult.alternatives.length > 0) {
            const alternatives = chatResult.alternatives.map(match => `${match.label} (${match.score})`);
            console.log(`Other possible chat matches for "${searchName}": ${alternatives.join(', ')}`);
        }

        const chatMatch = chatResult.match;
        if (chatMatch) {
            console.log(`Matched "${recipientName}" to WhatsApp chat "${chatMatch.label}" with score ${chatMatch.score}.`);
            return {
                label: chatMatch.label,
                sendMessage: (content, options) => chatMatch.candidate.sendMessage(content, options)
            };
        }
    }

    const contacts = await client.getContacts();
    if (searchName) {
        const contactCandidates = contacts
            .map(contact => ({
                contact,
                label: contact.name || contact.pushname || contact.shortName || contact.number || (contact.id && contact.id.user)
            }))
            .filter(entry => entry.label && entry.contact.id && entry.contact.id._serialized);
        const contactResult = pickBestNameMatch(searchName, contactCandidates, entry => entry.label);

        if (contactResult.ambiguous) {
            console.error(`Ambiguous recipient "${searchName}". Multiple contact matches had the same confidence:`);
            contactResult.tied.slice(0, 10).forEach(match => console.error(`  - ${match.label}`));
            throw new Error(`Recipient "${searchName}" matched multiple contacts. Use a more specific name or phone number.`);
        }

        if (contactResult.alternatives.length > 0) {
            const alternatives = contactResult.alternatives.map(match => `${match.label} (${match.score})`);
            console.log(`Other possible contact matches for "${searchName}": ${alternatives.join(', ')}`);
        }

        const contactMatch = contactResult.match;
        if (contactMatch) {
            console.log(`Matched "${recipientName}" to WhatsApp contact "${contactMatch.label}" with score ${contactMatch.score}.`);
            return {
                label: contactMatch.label,
                sendMessage: (content, options) => client.sendMessage(contactMatch.candidate.contact.id._serialized, content, options)
            };
        }
    }

    const phoneCandidate = normalizePhone(phone || recipientName);
    if (phoneCandidate) {
        const numberId = await client.getNumberId(phoneCandidate);
        if (numberId && numberId._serialized) {
            console.log(`Matched phone "${phone || recipientName}" to WhatsApp number "${numberId.user}".`);
            return {
                label: numberId.user,
                sendMessage: (content, options) => client.sendMessage(numberId._serialized, content, options)
            };
        }

        console.error(`Phone number "${phone || recipientName}" is not registered on WhatsApp.`);
    }

    console.error(`No chat or contact found matching "${recipientName}".`);
    console.log('\nAvailable chats:');
    chats.filter(c => c.name).slice(0, 30).forEach(c => console.log(`  - ${c.name}`));
    return null;
}

async function sendQueueItem(client, item) {
    const recipientName = item.recipient;
    const messageText = item.message;
    const attachments = item.attachments || [];
    const phone = item.phone || item.number;

    if (!recipientName && !phone) {
        throw new Error('Queue item is missing recipient or phone.');
    }

    const resolved = await resolveRecipient(client, recipientName, phone);
    if (!resolved) {
        throw new Error(`Could not resolve recipient "${recipientName || phone}".`);
    }

    console.log(`Sending to: ${resolved.label}`);
    await resolved.sendMessage(messageText);
    console.log('Text message sent.');

    for (const filePath of attachments) {
        if (!fs.existsSync(filePath)) {
            console.warn(`Attachment not found, skipping: ${filePath}`);
            continue;
        }

        const media = MessageMedia.fromFilePath(filePath);
        await resolved.sendMessage(media, { caption: path.basename(filePath) });
        console.log(`Attachment sent: ${path.basename(filePath)}`);
        await new Promise(resolve => setTimeout(resolve, 1000));
    }

    await new Promise(resolve => setTimeout(resolve, 3000));
}

async function dryRunQueueItem(client, item) {
    const recipientName = item.recipient;
    const attachments = item.attachments || [];
    const phone = item.phone || item.number;

    if (!recipientName && !phone) {
        throw new Error('Queue item is missing recipient or phone.');
    }

    const resolved = await resolveRecipient(client, recipientName, phone);
    if (!resolved) {
        throw new Error(`Could not resolve recipient "${recipientName || phone}".`);
    }

    console.log(`[dry-run] Recipient resolves to: ${resolved.label}`);

    for (const filePath of attachments) {
        if (!fs.existsSync(filePath)) {
            throw new Error(`[dry-run] Attachment not found: ${filePath}`);
        }

        console.log(`[dry-run] Attachment exists: ${filePath}`);
    }

    console.log('[dry-run] Text message would be sent.');
    console.log('[dry-run] No WhatsApp message, attachment, queue mutation, or shutdown was performed.');
}

// Load queue if needed
let queueItems = null;
if (fromQueue) {
    queueItems = readQueueItems();
    const filteredQueueItems = queueItems.filter(hasMessage);
    if (!dryRun && filteredQueueItems.length !== queueItems.length) {
        saveQueueItems(filteredQueueItems);
    }
    queueItems = filteredQueueItems;

    if (queueItems.length === 0) {
        console.log('Queue is empty - nothing to send.');
        process.exit(0);
    }
}

const directQueueItem = {
    recipient: recipientArg,
    message: messageArg,
    attachments: [],
    shutdown: false
};

function sleep(ms) {
    return new Promise(resolve => setTimeout(resolve, ms));
}

async function withRetry(label, attempts, task) {
    let lastError = null;

    for (let attempt = 1; attempt <= attempts; attempt++) {
        try {
            if (attempt > 1) {
                console.log(`${label}: retry attempt ${attempt} of ${attempts}.`);
            }
            return await task(attempt);
        } catch (err) {
            lastError = err;
            console.error(`${label}: attempt ${attempt} failed: ${err.message}`);
            if (attempt < attempts) {
                const delayMs = Math.min(30000, 2000 * Math.pow(2, attempt - 1));
                console.log(`${label}: waiting ${Math.round(delayMs / 1000)} seconds before retry.`);
                await sleep(delayMs);
            }
        }
    }

    throw lastError;
}

function createClient() {
    if (process.env.WHATSAPP_SCHED_FAKE_CLIENT === '1') {
        return createFakeClient();
    }

    const client = new Client({
        authStrategy: new LocalAuth({ dataPath: path.join(__dirname, '.wwebjs_auth') }),
        puppeteer: {
            headless: true,
            args: ['--no-sandbox', '--disable-setuid-sandbox', '--disable-dev-shm-usage', '--disable-gpu']
        }
    });

    client.on('qr', (qr) => {
        console.log('\nScan this QR code with WhatsApp on your phone:\n');
        qrcode.generate(qr, { small: true });
        console.log('\nWaiting for scan...');
    });

    client.on('authenticated', () => {
        console.log('Authenticated. Session saved.');
    });

    client.on('disconnected', (reason) => {
        console.warn('Client disconnected:', reason);
    });

    return client;
}

function createFakeClient() {
    const client = new EventEmitter();
    const chatName = process.env.WHATSAPP_SCHED_FAKE_CHAT || 'Mike Smith';
    const contactName = process.env.WHATSAPP_SCHED_FAKE_CONTACT || 'Jane Doe';
    const phoneUser = process.env.WHATSAPP_SCHED_FAKE_PHONE || '15551234567';

    client.initialize = async () => {
        setImmediate(() => client.emit('ready'));
    };
    client.destroy = async () => {};
    client.getChats = async () => [
        {
            name: chatName,
            sendMessage: async () => {
                throw new Error('Fake client sendMessage should not be called in dry-run mode.');
            }
        }
    ];
    client.getContacts = async () => [
        {
            name: contactName,
            id: { _serialized: `${phoneUser}@c.us`, user: phoneUser }
        }
    ];
    client.getNumberId = async (phone) => (
        phone === phoneUser ? { _serialized: `${phoneUser}@c.us`, user: phoneUser } : null
    );
    client.sendMessage = async () => {
        throw new Error('Fake client sendMessage should not be called in dry-run mode.');
    };

    return client;
}

function waitForReady(client) {
    return new Promise((resolve, reject) => {
        const timeout = setTimeout(() => {
            cleanup();
            reject(new Error('Timed out waiting for WhatsApp client to become ready.'));
        }, 120000);

        const onReady = () => {
            cleanup();
            resolve();
        };

        const onAuthFailure = (msg) => {
            cleanup();
            reject(new Error(`Authentication failed: ${msg}`));
        };

        const cleanup = () => {
            clearTimeout(timeout);
            client.off('ready', onReady);
            client.off('auth_failure', onAuthFailure);
        };

        client.once('ready', onReady);
        client.once('auth_failure', onAuthFailure);
    });
}

async function destroyClient(client) {
    if (!client) {
        return;
    }

    try {
        await client.destroy();
    } catch (err) {
        console.warn(`Client cleanup warning: ${err.message}`);
    }
}

async function initializeClientWithRetry() {
    return await withRetry('WhatsApp startup', 3, async () => {
        const client = createClient();
        const readyPromise = waitForReady(client);
        try {
            console.log('Initializing WhatsApp client.');
            await client.initialize();
            await readyPromise;
            console.log('WhatsApp client ready.');
            return client;
        } catch (err) {
            readyPromise.catch(() => {});
            await destroyClient(client);
            if (err && err.message && err.message.includes('browser is already running')) {
                throw new Error(`${err.message} A previous Chromium session may still be using .wwebjs_auth.`);
            }
            throw err;
        }
    });
}

async function main() {
    let client = null;

    try {
        client = await initializeClientWithRetry();

        if (authOnly) {
            console.log('Auth-only mode - session saved. Exiting.');
            await destroyClient(client);
            process.exit(0);
        }

        if (fromQueue) {
            let shouldShutdown = false;

            while (queueItems.length > 0) {
                const item = queueItems[0];
                console.log(`Processing queued message 1 of ${queueItems.length}.`);

                if (dryRun) {
                    await withRetry('Queue item dry-run', 1, async () => dryRunQueueItem(client, item));
                    queueItems.shift();
                    continue;
                }

                delete item.lastError;
                delete item.lastAttemptAt;
                saveQueueItems(queueItems);
                await withRetry('Queue item send', 3, async () => sendQueueItem(client, item));

                if (item.shutdown === true) {
                    shouldShutdown = true;
                }

                queueItems.shift();
                saveQueueItems(queueItems);
                console.log(`Queue item sent and removed. Remaining items: ${queueItems.length}.`);
            }

            if (dryRun) {
                console.log('[dry-run] Queue validation completed. Queue file was not changed.');
            } else {
                removeCompletedQueueFileIfSafe();

                if (shouldShutdown) {
                    console.log('Shutting down in 2 minutes. Run "shutdown /a" to cancel.');
                    exec('shutdown /s /t 120');
                }
            }
        } else {
            if (dryRun) {
                await withRetry('Direct dry-run', 1, async () => dryRunQueueItem(client, directQueueItem));
            } else {
                await withRetry('Direct send', 3, async () => sendQueueItem(client, directQueueItem));
            }
        }

        await destroyClient(client);
        process.exit(0);
    } catch (err) {
        console.error('Error:', err.message);
        if (!dryRun) {
            markFirstQueueItemError(err);
        }
        await destroyClient(client);
        process.exit(1);
    }
}

main();
