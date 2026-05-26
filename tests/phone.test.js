const test = require('node:test');
const assert = require('node:assert/strict');

const { normalizePhone } = require('../lib/phone');

test('normalizePhone strips formatting and adds US country code for 10 digit numbers', () => {
    assert.equal(normalizePhone('(555) 123-4567'), '15551234567');
    assert.equal(normalizePhone('555.123.4567'), '15551234567');
});

test('normalizePhone preserves explicit country code numbers', () => {
    assert.equal(normalizePhone('+1 555 123 4567'), '15551234567');
    assert.equal(normalizePhone('+44 20 7946 0958'), '442079460958');
});

test('normalizePhone rejects empty, non-string, and too-short values', () => {
    assert.equal(normalizePhone('555-1212'), null);
    assert.equal(normalizePhone(''), null);
    assert.equal(normalizePhone(null), null);
    assert.equal(normalizePhone(15551234567), null);
});
