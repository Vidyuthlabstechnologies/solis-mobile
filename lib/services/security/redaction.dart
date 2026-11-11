/// Removes identifiers a note never needs before a transcript leaves the
/// phone: Social Security numbers, Medicare Beneficiary Identifiers and
/// payment card numbers. Clinical content is left as it is.
///
/// SSNs are caught in the 3-2-4 form with dashes or spaces, and as nine bare
/// digits only right after "social", "SSN" or "security number", so ZIP
/// codes, phone numbers and doses are not touched. Card numbers must pass
/// the Luhn check.
String redactIdentifiers(String text) {
  var out = text.replaceAllMapped(
    RegExp(r'\b(?!000|666|9\d\d)\d{3}([- ])(?!00)\d{2}\1(?!0000)\d{4}\b'),
    (_) => '[SSN]',
  );
  out = out.replaceAllMapped(
    RegExp(r'\b(social(\s+security)?(\s+number)?|ssn|security number)(\s+(is|was|of))?[\s:#]*(\d{9})\b', caseSensitive: false),
    (m) => '${m.group(0)!.substring(0, m.group(0)!.length - 9)}[SSN]',
  );
  // MBI: 11 characters, C A AN N A AN N A A N N (no S, L, O, I, B, Z).
  const a = '[AC-HJKMNP-RT-Y]';
  const an = '[AC-HJKMNP-RT-Y0-9]';
  out = out.replaceAllMapped(
    RegExp('\\b[1-9]$a$an[0-9]-?$a$an[0-9]-?$a$a[0-9]{2}\\b', caseSensitive: false),
    (_) => '[MBI]',
  );
  out = out.replaceAllMapped(RegExp(r'\b(?:\d[ -]?){12,18}\d\b'), (m) {
    final digits = m.group(0)!.replaceAll(RegExp(r'[ -]'), '');
    return digits.length >= 13 && digits.length <= 19 && _luhn(digits) ? '[CARD]' : m.group(0)!;
  });
  return out;
}

bool _luhn(String digits) {
  var sum = 0;
  for (var i = 0; i < digits.length; i++) {
    var d = int.parse(digits[digits.length - 1 - i]);
    if (i.isOdd) {
      d *= 2;
      if (d > 9) d -= 9;
    }
    sum += d;
  }
  return sum % 10 == 0;
}
