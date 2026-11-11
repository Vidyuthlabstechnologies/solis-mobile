/// The words a clinician agrees to when signing a note. Each change to the
/// wording gets a new [attestationVersion], and every signed note stores
/// the version and the exact text it was signed under, so an auditor can
/// see what was attested even after the wording changes.
const attestationVersion = 'solis-attest-2026-11-v1';

String attestationText(String signer) =>
    'I personally performed this encounter and reviewed this note for accuracy. Signing as $signer.';
