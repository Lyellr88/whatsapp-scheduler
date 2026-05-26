function normalizeName(input) {
    return String(input || '')
        .toLowerCase()
        .replace(/[^a-z0-9]+/g, ' ')
        .trim()
        .replace(/\s+/g, ' ');
}

function scoreNameMatch(searchName, candidateName) {
    const search = normalizeName(searchName);
    const candidate = normalizeName(candidateName);

    if (!search || !candidate) {
        return 0;
    }

    if (candidate === search) {
        return 100;
    }

    if (candidate.startsWith(`${search} `)) {
        return 90;
    }

    const words = candidate.split(' ');
    if (words.includes(search)) {
        return 80;
    }

    if (candidate.includes(` ${search} `) || candidate.endsWith(` ${search}`)) {
        return 70;
    }

    if (candidate.includes(search)) {
        return 50;
    }

    return 0;
}

function rankNameMatches(searchName, candidates, labelForCandidate) {
    return candidates
        .map(candidate => ({
            candidate,
            label: labelForCandidate(candidate),
            score: scoreNameMatch(searchName, labelForCandidate(candidate))
        }))
        .filter(match => match.score > 0)
        .sort((a, b) => b.score - a.score || a.label.localeCompare(b.label));
}

function pickBestNameMatch(searchName, candidates, labelForCandidate) {
    const ranked = rankNameMatches(searchName, candidates, labelForCandidate);

    if (ranked.length === 0) {
        return {
            match: null,
            ambiguous: false,
            tied: [],
            alternatives: []
        };
    }

    const best = ranked[0];
    const tied = ranked.filter(match => match.score === best.score);

    return {
        match: tied.length === 1 ? best : null,
        ambiguous: tied.length > 1,
        tied,
        alternatives: ranked.filter(match => match !== best).slice(0, 5)
    };
}

module.exports = {
    normalizeName,
    scoreNameMatch,
    rankNameMatches,
    pickBestNameMatch
};
