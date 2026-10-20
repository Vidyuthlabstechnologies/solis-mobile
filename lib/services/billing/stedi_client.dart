// Stedi Healthcare APIs.
//
// Auth: https://www.stedi.com/docs/api-reference (Authorization header carries the API key)
// Raw X12 837P: https://www.stedi.com/docs/api-reference/healthcare/post-healthcare-claims-raw-x12
// Eligibility 270/271: https://www.stedi.com/docs/api-reference/healthcare/post-healthcare-eligibility
// Claim status 276/277: https://www.stedi.com/docs/api-reference/healthcare/post-healthcare-claim-status

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../net/pinned_http.dart';
import '../solis_backend.dart';

import '../../models/patient_account.dart' show PatientSex;
import 'clearinghouse.dart';
import 'cms_edi_edits.dart';

class StediClient implements ClearinghouseClient {
  static final Uri defaultBaseUrl = Uri.parse('https://healthcare.us.stedi.com/2024-04-01');
  static const claimsPath = '/change/medicalnetwork/professionalclaims/v3/raw-x12-submission';
  static const eligibilityPath = '/change/medicalnetwork/eligibility/v3';
  static const claimStatusPath = '/change/medicalnetwork/claimstatus/v2';

  final String _apiKey;
  final Future<Map<String, String>> Function()? _extraHeaders;
  final http.Client _http;
  final Uri baseUrl;
  final Duration timeout;
  final ({String claims, String eligibility, String claimStatus}) _paths;

  StediClient({
    required String apiKey,
    http.Client? httpClient,
    Uri? baseUrl,
    this.timeout = const Duration(seconds: 60),
  })  : _apiKey = apiKey.trim(),
        _extraHeaders = null,
        _http = httpClient ?? http.Client(),
        baseUrl = baseUrl ?? defaultBaseUrl,
        _paths = (claims: claimsPath, eligibility: eligibilityPath, claimStatus: claimStatusPath);

  /// Through the SOLIS Worker, which holds the Stedi key: the app sends only
  /// its own token, and the request and response bodies are Stedi's own.
  StediClient.viaBackend(SolisBackend backend, {http.Client? httpClient, this.timeout = const Duration(seconds: 90)})
      : _apiKey = 'Bearer ${backend.appToken}',
        _extraHeaders = backend.sessionHeaders,
        _http = httpClient ?? PinnedHttp.client(),
        baseUrl = backend.uri('/stedi'),
        _paths = (claims: '/claims-x12', eligibility: '/eligibility', claimStatus: '/claim-status');

  bool get hasApiKey => _apiKey.isNotEmpty;

  Uri _uri(String path) => baseUrl.replace(path: '${baseUrl.path}$path');

  Map<String, String> _headers({String? idempotencyKey}) => {
        'Authorization': _apiKey,
        'Content-Type': 'application/json',
        'Accept': 'application/json',
        if (idempotencyKey != null && idempotencyKey.isNotEmpty) 'Idempotency-Key': idempotencyKey,
      };

  Future<http.Response> _post(String path, Map<String, dynamic> body, {String? idempotencyKey}) async {
    // Through the SOLIS server the signed-in clinician's session goes along too.
    final extra = await _extraHeaders?.call() ?? const <String, String>{};
    return _http
        .post(_uri(path), headers: {..._headers(idempotencyKey: idempotencyKey), ...extra}, body: jsonEncode(body))
        .timeout(timeout);
  }

  // ---------------------------------------------------------------- 837P

  @override
  Future<ClaimSubmissionResult> submitClaim(String x12, {String? idempotencyKey}) async {
    if (!hasApiKey) return _noKeySubmission();
    // Stedi expects one compact interchange; drop line breaks from pretty output.
    final compact = x12.replaceAll('\r', '').replaceAll('\n', '');
    final http.Response res;
    try {
      res = await _post(_paths.claims, {'x12': compact}, idempotencyKey: idempotencyKey);
    } catch (e) {
      return ClaimSubmissionResult(
        outcome: SubmissionOutcome.failed,
        httpStatus: 0,
        rawResponse: '',
        errors: [ClearinghouseError(description: 'Could not reach Stedi: ${e.runtimeType}')],
      );
    }
    return parseSubmission(res.statusCode, res.body);
  }

  /// Parses a raw X12 claim submission response. Public for tests.
  static ClaimSubmissionResult parseSubmission(int statusCode, String body) {
    final j = _decode(body);
    final errors = <ClearinghouseError>[..._errorList(j['errors']), ..._editErrors(j['editResponses'])];
    final ref = _map(j['claimReference']);
    final payer = _map(j['payer']);
    final status = _str(j['status']);
    final ok2xx = statusCode >= 200 && statusCode < 300;

    SubmissionOutcome outcome;
    if (ok2xx) {
      final success = (status ?? '').toUpperCase() == 'SUCCESS';
      outcome = success && errors.isEmpty ? SubmissionOutcome.accepted : SubmissionOutcome.rejected;
      if (!success && errors.isEmpty) {
        errors.add(ClearinghouseError(description: 'Stedi returned status ${status ?? 'unknown'}.'));
      }
    } else {
      _addTopLevelMessage(j, statusCode, errors);
      outcome = (statusCode == 400 || statusCode == 422) ? SubmissionOutcome.rejected : SubmissionOutcome.failed;
    }

    return ClaimSubmissionResult(
      outcome: outcome,
      httpStatus: statusCode,
      rawResponse: body,
      status: status,
      controlNumber: _str(j['controlNumber']),
      correlationId: _str(ref['correlationId']),
      patientControlNumber: _str(ref['patientControlNumber']),
      payerName: _str(payer['payerName']),
      payerId: _str(payer['payerId']) ?? _str(payer['payerID']),
      testMode: _testMode(j),
      errors: errors,
    );
  }

  ClaimSubmissionResult _noKeySubmission() => const ClaimSubmissionResult(
        outcome: SubmissionOutcome.failed,
        httpStatus: 0,
        rawResponse: '',
        errors: [ClearinghouseError(description: 'No Stedi API key is set.')],
      );

  // ---------------------------------------------------------------- 270/271

  /// JSON body for a real-time eligibility check. Public for tests.
  static Map<String, dynamic> eligibilityBody(EligibilityRequest r) {
    final a = r.account;
    final p = r.provider;
    final ins = a.insurance;
    final dob = a.dateOfBirth;
    final groupNpi = p.groupNpi?.trim() ?? '';
    final dos = r.dateOfService == null ? null : _d8(r.dateOfService!);
    return {
      'tradingPartnerServiceId': r.payerId.trim(),
      'provider': {
        'organizationName': p.practiceName.trim(),
        'npi': groupNpi.isNotEmpty ? groupNpi : p.npi.trim(),
      },
      'subscriber': {
        if (ins != null && ins.memberId.trim().isNotEmpty) 'memberId': ins.memberId.trim(),
        'firstName': a.firstName.trim(),
        'lastName': a.lastName.trim(),
        if (dob != null) 'dateOfBirth': _dateDigits(dob),
      },
      'encounter': {
        'serviceTypeCodes': r.serviceTypeCodes,
        'dateOfService': ?dos,
      },
    };
  }

  @override
  Future<EligibilityResult> checkEligibility(EligibilityRequest request) async {
    if (!hasApiKey) {
      return const EligibilityResult(
        success: false,
        httpStatus: 0,
        rawResponse: '',
        errors: [ClearinghouseError(description: 'No Stedi API key is set.')],
      );
    }
    final http.Response res;
    try {
      res = await _post(_paths.eligibility, eligibilityBody(request));
    } catch (e) {
      return EligibilityResult(
        success: false,
        httpStatus: 0,
        rawResponse: '',
        errors: [ClearinghouseError(description: 'Could not reach Stedi: ${e.runtimeType}')],
      );
    }
    return parseEligibility(res.statusCode, res.body, serviceTypeCodes: request.serviceTypeCodes);
  }

  /// Parses a 271 JSON response. Public for tests.
  static EligibilityResult parseEligibility(int statusCode, String body, {List<String> serviceTypeCodes = const ['30']}) {
    final j = _decode(body);
    final errors = <ClearinghouseError>[..._errorList(j['errors'])];
    for (final d in _list(j['dependents'])) {
      errors.addAll(_errorList(_map(d)['aaaErrors']));
    }
    errors.addAll(_errorList(_map(j['subscriber'])['aaaErrors']));
    final ok2xx = statusCode >= 200 && statusCode < 300;
    if (!ok2xx) _addTopLevelMessage(j, statusCode, errors);

    final benefits = _list(j['benefitsInformation']).map(_map).toList();
    final planStatus = _list(j['planStatus']).map(_map).toList();

    bool? active;
    final statusCodes = planStatus.map((s) => _str(s['statusCode'])).whereType<String>().toSet();
    final benefitCodes = benefits.map((b) => _str(b['code'])).whereType<String>().toSet();
    if (statusCodes.contains('1') || (statusCodes.isEmpty && benefitCodes.contains('1'))) {
      active = true;
    } else if (statusCodes.any(const {'6', '7', '8'}.contains) || benefitCodes.contains('6')) {
      active = false;
    }

    String? planName;
    for (final s in planStatus) {
      planName ??= _str(s['planDetails']);
    }
    for (final b in benefits) {
      if (_str(b['code']) == '1') planName ??= _str(b['planCoverage']);
    }
    final planInfo = _map(j['planInformation']);
    final sub = _map(j['subscriber']);
    final groupNumber = _str(planInfo['groupNumber']) ?? _str(sub['groupNumber']);

    final copay = _pick(benefits, code: 'B', stcs: ['98', ...serviceTypeCodes], field: 'benefitAmount');
    final coins = _pick(benefits, code: 'A', stcs: ['98', ...serviceTypeCodes], field: 'benefitPercent');
    final deductible = _pick(benefits, code: 'C', stcs: serviceTypeCodes, field: 'benefitAmount', timeQualifier: '29');
    final oop = _pick(benefits, code: 'G', stcs: serviceTypeCodes, field: 'benefitAmount', timeQualifier: '29');

    return EligibilityResult(
      success: ok2xx && errors.isEmpty,
      httpStatus: statusCode,
      rawResponse: body,
      activeCoverage: active,
      planName: planName,
      groupNumber: groupNumber,
      copay: copay,
      coinsurancePercent: coins == null ? null : _percent(coins),
      deductibleRemaining: deductible,
      outOfPocketRemaining: oop,
      testMode: _testMode(j),
      errors: errors,
    );
  }

  /// Best matching benefit value: prefers in-network, individual level, and the
  /// earliest listed service type.
  static String? _pick(
    List<Map<String, dynamic>> benefits, {
    required String code,
    required List<String> stcs,
    required String field,
    String? timeQualifier,
  }) {
    String? best;
    var bestScore = -1;
    for (final b in benefits) {
      if (_str(b['code']) != code) continue;
      if (timeQualifier != null && _str(b['timeQualifierCode']) != timeQualifier) continue;
      final value = _str(b[field]);
      if (value == null) continue;
      var score = 0;
      final net = _str(b['inPlanNetworkIndicatorCode']);
      if (net == 'Y') score += 100;
      if (net == 'W') score += 50;
      final level = _str(b['coverageLevelCode']);
      if (level == null || level == 'IND') score += 20;
      final types = _list(b['serviceTypeCodes']).map((e) => e.toString()).toList();
      for (var i = 0; i < stcs.length; i++) {
        if (types.contains(stcs[i])) {
          score += 10 * (stcs.length - i);
          break;
        }
      }
      if (score > bestScore) {
        bestScore = score;
        best = value;
      }
    }
    return best;
  }

  static String _percent(String raw) {
    final v = double.tryParse(raw);
    if (v == null) return raw;
    final pct = v <= 1 ? v * 100 : v;
    return pct == pct.roundToDouble() ? pct.round().toString() : pct.toStringAsFixed(1);
  }

  // ---------------------------------------------------------------- 276/277

  /// JSON body for a real-time claim status check. Public for tests.
  static Map<String, dynamic> claimStatusBody(ClaimStatusRequest r) {
    final a = r.account;
    final p = r.provider;
    final groupNpi = p.groupNpi?.trim() ?? '';
    final dob = a.dateOfBirth;
    final from = _d8(r.dateOfServiceFrom) ?? r.dateOfServiceFrom;
    final to = r.dateOfServiceTo == null ? from : (_d8(r.dateOfServiceTo!) ?? r.dateOfServiceTo!);
    // 2100C NM103 must be present: the practice, else the provider's own name.
    final org = p.practiceName.trim();
    final person = p.fullName.trim().split(RegExp(r'\s+')).where((s) => s.isNotEmpty).toList();
    return {
      'tradingPartnerServiceId': r.payerId.trim(),
      'providers': [
        {
          if (org.isNotEmpty) 'organizationName': org,
          if (org.isEmpty && person.length > 1) 'firstName': person.first,
          if (org.isEmpty && person.isNotEmpty) 'lastName': person.last,
          'npi': groupNpi.isNotEmpty ? groupNpi : p.npi.trim(),
          'providerType': 'BillingProvider',
        },
      ],
      'subscriber': {
        // Medicare 276: MBI without the dashes printed on the card.
        if (a.insurance != null) 'memberId': a.insurance!.memberId.trim().replaceAll('-', ''),
        'firstName': a.firstName.trim(),
        'lastName': a.lastName.trim(),
        if (dob != null) 'dateOfBirth': _dateDigits(dob),
        // 2000D DMG03, which the Medicare 276 edits require.
        if (a.sex != PatientSex.unknown) 'gender': a.sex == PatientSex.female ? 'F' : 'M',
      },
      'encounter': {
        'beginningDateOfService': from,
        'endDateOfService': to,
      },
    };
  }

  @override
  Future<ClaimStatusResult> claimStatus(ClaimStatusRequest request) async {
    if (!hasApiKey) {
      return const ClaimStatusResult(
        success: false,
        httpStatus: 0,
        rawResponse: '',
        errors: [ClearinghouseError(description: 'No Stedi API key is set.')],
      );
    }
    // Medicare 276 front-end edits (CMS CR 14429): fix the data here instead
    // of waiting for a rejected 277.
    final problems = CmsEdiEdits.claimStatusProblems(request);
    if (problems.isNotEmpty) {
      return ClaimStatusResult(success: false, httpStatus: 0, rawResponse: '', errors: problems);
    }
    final http.Response res;
    try {
      res = await _post(_paths.claimStatus, claimStatusBody(request));
    } catch (e) {
      return ClaimStatusResult(
        success: false,
        httpStatus: 0,
        rawResponse: '',
        errors: [ClearinghouseError(description: 'Could not reach Stedi: ${e.runtimeType}')],
      );
    }
    return parseClaimStatus(res.statusCode, res.body);
  }

  /// Parses a 277 JSON response. Public for tests.
  static ClaimStatusResult parseClaimStatus(int statusCode, String body) {
    final j = _decode(body);
    final errors = <ClearinghouseError>[..._errorList(j['errors'])];
    final er = _map(j['errorResponse']);
    if (er.isNotEmpty) {
      errors.addAll(_errorList(er['errors']));
      final d = _str(er['description']);
      if (d != null && errors.isEmpty) errors.add(ClearinghouseError(code: _str(er['code']), description: d));
    }
    final ok2xx = statusCode >= 200 && statusCode < 300;
    if (!ok2xx) _addTopLevelMessage(j, statusCode, errors);

    final claims = <ClaimStatusEntry>[];
    for (final c in _list(j['claims'])) {
      final s = _map(_map(c)['claimStatus']);
      if (s.isEmpty) continue;
      claims.add(ClaimStatusEntry(
        statusCategoryCode: _str(s['statusCategoryCode']),
        statusCategory: _str(s['statusCategoryCodeValue']),
        statusCode: _str(s['statusCode']),
        statusDescription: _str(s['statusCodeValue']),
        serviceDate: _str(s['claimServiceDate']),
        submittedAmount: _str(s['submittedAmount']),
        paidAmount: _str(s['amountPaid']),
        effectiveDate: _str(s['effectiveDate']),
        payerClaimNumber: _str(s['tradingPartnerClaimNumber']),
        patientAccountNumber: _str(s['patientAccountNumber']),
      ));
    }
    return ClaimStatusResult(
      success: ok2xx && errors.isEmpty,
      httpStatus: statusCode,
      rawResponse: body,
      claims: claims,
      errors: errors,
    );
  }

  // ---------------------------------------------------------------- helpers

  @override
  String toString() => 'StediClient(baseUrl: $baseUrl, apiKey: ${hasApiKey ? 'set' : 'missing'})';

  static Map<String, dynamic> _decode(String body) {
    if (body.trim().isEmpty) return const {};
    try {
      final v = jsonDecode(body);
      return v is Map ? v.cast<String, dynamic>() : const {};
    } catch (_) {
      return const {};
    }
  }

  static Map<String, dynamic> _map(Object? v) => v is Map ? v.cast<String, dynamic>() : const {};

  static List<Object?> _list(Object? v) => v is List ? v : const [];

  static String? _str(Object? v) {
    if (v == null) return null;
    if (v is String) return v.trim().isEmpty ? null : v.trim();
    if (v is num || v is bool) return v.toString();
    return null;
  }

  static List<ClearinghouseError> _errorList(Object? v) => [
        for (final e in _list(v))
          if (e is Map)
            ClearinghouseError(
              code: _str(e['code']),
              description: _str(e['description']) ?? _str(e['message']) ?? 'Unspecified error',
              followupAction: _str(e['followupAction']),
              location: _str(e['location']) ?? _str(e['field']),
            )
          else if (_str(e) != null)
            ClearinghouseError(description: _str(e)!),
      ];

  static List<ClearinghouseError> _editErrors(Object? v) => [
        for (final e in _list(v))
          if (e is Map && (_str(e['errorDescription']) != null))
            ClearinghouseError(
              code: _str(e['qualifierCode']) ?? _str(e['editName']),
              description: _str(e['errorDescription'])!,
              location: [_str(e['segment']), _str(e['element'])].whereType<String>().join(' ').trim().isEmpty
                  ? null
                  : [_str(e['segment']), _str(e['element'])].whereType<String>().join(' '),
            ),
      ];

  static void _addTopLevelMessage(Map<String, dynamic> j, int statusCode, List<ClearinghouseError> errors) {
    final msg = _str(j['message']) ?? _str(_map(j['failure'])['description']);
    if (msg != null) {
      errors.add(ClearinghouseError(code: _str(j['code']) ?? 'HTTP $statusCode', description: msg));
    } else if (errors.isEmpty) {
      errors.add(ClearinghouseError(code: 'HTTP $statusCode', description: _httpReason(statusCode)));
    }
  }

  static String _httpReason(int code) => switch (code) {
        400 => 'The request was not valid.',
        401 || 403 => 'The API key was refused. Check the key, and that a test key is not used for production traffic.',
        404 => 'Endpoint not found.',
        409 => 'A request with this idempotency key is already in progress.',
        422 => 'The request could not be processed.',
        429 => 'Rate limited by Stedi; try again shortly.',
        >= 500 => 'Stedi or the payer is unavailable; try again later.',
        _ => 'Unexpected response.',
      };

  static bool? _testMode(Map<String, dynamic> j) {
    final mode = _str(_map(j['meta'])['applicationMode']);
    return mode == null ? null : mode.toLowerCase() == 'test';
  }

  static String _two(int n) => n.toString().padLeft(2, '0');

  static String _dateDigits(DateTime d) => '${d.year.toString().padLeft(4, '0')}${_two(d.month)}${_two(d.day)}';

  static String? _d8(String yyyyMmDd) {
    final m = RegExp(r'^(\d{4})-?(\d{2})-?(\d{2})$').firstMatch(yyyyMmDd.trim());
    return m == null ? null : '${m.group(1)}${m.group(2)}${m.group(3)}';
  }
}
