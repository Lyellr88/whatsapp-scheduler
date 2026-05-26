const test = require('node:test');
const assert = require('node:assert/strict');

const {
    normalizeName,
    pickBestNameMatch,
    rankNameMatches,
    scoreNameMatch
} = require('../lib/matching');

const label = value => value;

test('normalizeName lowercases, strips punctuation, and collapses whitespace', () => {
    assert.equal(normalizeName('  Mike   O. Smith!! '), 'mike o smith');
});

test('exact match beats prefix match', () => {
    const result = pickBestNameMatch('mike smith', ['Mike', 'Mike Smith'], label);

    assert.equal(result.ambiguous, false);
    assert.equal(result.match.label, 'Mike Smith');
    assert.equal(scoreNameMatch('mike smith', 'Mike Smith'), 100);
});

test('prefix match beats substring match', () => {
    const ranked = rankNameMatches('mike', ['The Mike Group', 'Mike Smith'], label);

    assert.deepEqual(ranked.map(match => match.label), ['Mike Smith', 'The Mike Group']);
    assert.equal(ranked[0].score, 90);
    assert.equal(ranked[1].score, 80);
});

test('whole word match beats loose substring match', () => {
    const ranked = rankNameMatches('ann', ['Joanne', 'Ann Marie'], label);

    assert.deepEqual(ranked.map(match => match.label), ['Ann Marie', 'Joanne']);
    assert.equal(ranked[0].score, 90);
    assert.equal(ranked[1].score, 50);
});

test('ambiguous equal-score matches fail safe instead of choosing first', () => {
    const result = pickBestNameMatch('mike', ['Mike Smith', 'Mike Jones'], label);

    assert.equal(result.match, null);
    assert.equal(result.ambiguous, true);
    assert.deepEqual(result.tied.map(match => match.label), ['Mike Jones', 'Mike Smith']);
});

test('no match returns an explicit empty result', () => {
    const result = pickBestNameMatch('zelda', ['Mike Smith', 'Jane Doe'], label);

    assert.deepEqual(result, {
        match: null,
        ambiguous: false,
        tied: [],
        alternatives: []
    });
});
