function normalizePhone(input) {
    if (!input || typeof input !== 'string') {
        return null;
    }

    let digits = input.replace(/\D/g, '');
    if (digits.length === 10) {
        digits = `1${digits}`;
    }

    return digits.length >= 11 ? digits : null;
}

module.exports = {
    normalizePhone
};
