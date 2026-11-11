import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:speech_to_text/speech_recognition_result.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;

import '../data/sample_conversations.dart';
import '../models/ambulance_transport.dart';
import '../models/claim_models.dart';
import '../models/clinical_models.dart';
import '../models/patient_account.dart';
import '../models/provider_profile.dart';
import '../services/account_repository.dart';
import '../services/billing/claim_submission_service.dart';
import '../services/billing/eligibility_service.dart';
import '../services/billing/rejection_fixes.dart';
import '../services/billing/x12_837p.dart';
import '../services/coding/claim_builder.dart';
import '../services/codesets/reference_data.dart';
import '../services/integrations.dart';
import '../services/solis_backend.dart';
import '../services/transcription/engine_selector.dart';
import '../services/transcription/transcription_provider.dart';
import '../services/coding/claim_scrubber.dart';
import '../services/coding/clinical_coder.dart';
import '../services/coding/place_of_service.dart';
import '../services/fhir_export_service.dart';
import '../services/local_clinical_engine.dart';
import '../services/attestation.dart';
import '../services/note_seal.dart';
import '../services/note_sources.dart';
import '../services/places.dart';
import '../services/recording_foreground_service.dart';
import '../services/security_and_background_service.dart';
import '../services/security/phi_clipboard.dart';
import '../theme/solis_theme.dart';
import '../widgets/encounter_widgets.dart';
import '../widgets/sign_and_send_sheet.dart';
import '../widgets/signature_pad.dart';
import 'claim_tab.dart';
import 'paywall_screen.dart';
import 'patients_screen.dart';
import 'provider_profile_screen.dart';
import 'scan_card_screen.dart';

/// Phases of a visit. The screen shows exactly one primary task per phase:
/// capture the conversation, wait for the note, or review and sign it.
enum _Phase { ready, recording, generating, review }

/// One visit (date of service) under a patient account: capture the
/// conversation, review and sign the note, then build the claim.
class EncounterScreen extends StatefulWidget {
  final String accountNumber;
  final int visitNumber;
  final bool isDark;
  final ValueChanged<bool>? onThemeToggle;

  /// Renders the recording state with sample text and no platform calls.
  /// Used by screenshot tests, where no microphone exists.
  @visibleForTesting
  final bool previewRecording;

  /// Review tab to open on (0 note, 1 talk, 2 orders, 3 claim). The Billing
  /// queue opens claims on the Claim tab.
  final int initialReviewTab;

  const EncounterScreen({
    super.key,
    required this.accountNumber,
    required this.visitNumber,
    this.isDark = false,
    this.onThemeToggle,
    this.previewRecording = false,
    this.initialReviewTab = 0,
  });

  @override
  State<EncounterScreen> createState() => _EncounterScreenState();
}

class _EncounterScreenState extends State<EncounterScreen> with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  // Engine and environment. The note engine starts from the clinician's
  // saved preference (cloud writes with Claude through the SOLIS server and
  // falls back to this phone when offline).
  late bool _isOffline = _repo.provider.preferOnDevice;

  // Microphone settings applied when recording starts: Android's noise
  // suppressor and the recognition language. Both change real recognizer
  // settings (see CaptureSettings).
  bool _noiseSuppression = true;
  SpeechLanguage _language = SpeechLanguage.english;
  bool _isFlagSecureActive = true;
  bool _isBackgroundWakeLockActive = false;
  bool _gpsResolved = false;

  // Capture state
  bool _isRecording = false;
  bool _isPaused = false;
  bool _isProcessing = false;
  int _recordSeconds = 0;
  Timer? _recordTimer;

  // The recording is saved to the visit every few seconds and whenever the
  // app leaves the foreground, so a killed app, a phone call or a crash loses
  // at most the last few seconds. [_interrupted] is a recording found still
  // running when the visit was opened.
  static const _checkpointEvery = Duration(seconds: 5);
  Timer? _checkpointTimer;
  DateTime? _recordingStartedUtc;
  String _checkpointedText = '';
  RecordingCheckpoint? _interrupted;
  Timer? _listenRestartTimer;

  // Microphone level from the capture source actually in use (0 to 1), and
  // when sound or words last arrived, for the "no sound" warning.
  final ValueNotifier<double> _micLevel = ValueNotifier(0);
  VoidCallback? _detachLevel;
  int _silentSeconds = 0;
  bool _noSound = false;

  /// Below this level the room is treated as silent.
  static const _noiseFloor = 0.15;

  /// Seconds without sound or words before the "no sound" warning.
  static const _noSoundSeconds = 10;

  // Location fixes taken while recording an ambulance visit, summed into
  // loaded miles (every value stays editable).
  final List<Map<String, dynamic>> _gpsTrack = [];
  Timer? _gpsTrackTimer;
  Timer? _locatingTimeout;
  late final AnimationController _pulseController;
  final ScrollController _liveScroll = ScrollController();

  // Consent is confirmed once per encounter, before the first recording.
  bool _consentConfirmed = false;
  DateTime? _consentAtUtc;
  ConsentRecord? _consentRecord;

  // Review state
  late int _reviewTab = widget.initialReviewTab; // 0 note, 1 transcript, 2 orders, 3 claim
  bool _hideSmallTalk = false;
  bool _isSigned = false;
  DateTime? _signedAt;
  final GlobalKey _checksKey = GlobalKey();
  final Map<String, bool> _editing = {};

  // Async race guards: a monotonically increasing synthesis id lets a slow cloud
  // response detect that a newer request (patient switch, discard) superseded it,
  // and the toggle flag blocks double-taps while the wake lock / mic are starting.
  int _synthesisGeneration = 0;
  bool _isTogglingRecording = false;

  // Speech recognition. Android ends a listen session after a pause, so the
  // recorder restarts sessions while recording and appends each one to the
  // committed transcript instead of overwriting it.
  final stt.SpeechToText _speech = stt.SpeechToText();
  bool _speechEnabled = false;
  String _committedTranscript = '';
  int _listenSession = 0;
  int _committedSession = 0;

  // Voice separation engine (Deepgram or on-device). When one is running it
  // replaces Android speech recognition and labels Doctor / Patient by voice.
  TranscriptionProvider? _engine;
  StreamSubscription<TranscriptUpdate>? _engineSub;

  /// Stop pressed in the Android recording notification.
  StreamSubscription<void>? _notificationStop;

  /// True while the microphone foreground service runs for this recording
  /// (it holds the wake lock then; otherwise this screen holds it).
  bool _foregroundServiceActive = false;
  SpeechEngine _engineKind = SpeechEngine.basic;

  // Account and visit this screen documents.
  AccountRepository get _repo => AccountRepository.instance;
  PatientAccount get _account => _repo.byNumber(widget.accountNumber)!;
  Visit? get _visitOrNull => _repo.byNumber(widget.accountNumber)?.visit(widget.visitNumber);
  Visit get _visit => _visitOrNull!;
  String get _patientName => _account.fullName;
  String get _mrn => _account.accountNumber;
  String get _ageGender => _account.ageSex;
  String get _visitType => 'Visit ${widget.visitNumber}, ${placeOfService(_visit.placeOfService).name}';
  String get _attending => '${_repo.provider.displayName} (NPI: ${_repo.provider.npi})';

  // Billing
  ClaimDraft? _claim;
  bool _claimReady = false;
  VisitStatus? _afterReady; // queued, submitted, rejected, paid or denied
  Map<String, dynamic>? _submission;
  bool _submitting = false;
  final ClaimSubmissionService _claims = ClaimSubmissionService();
  final EligibilityService _eligibility = EligibilityService();

  late ClinicalEncounter _encounter;
  final TextEditingController _transcriptController = TextEditingController();
  late final Map<String, TextEditingController> _soapControllers = {
    for (final k in const ['subjective', 'objective', 'assessment', 'plan']) k: TextEditingController(),
  };

  // Real device fix from the native helper; `available: false` until one arrives.
  Map<String, dynamic> _currentGps = const {'available': false, 'reason': 'locating'};

  bool get _hasFix => _currentGps['available'] == true;

  String get _locationLabel {
    if (_hasFix) {
      final acc = (_currentGps['accuracy'] as num?)?.round();
      return acc == null ? 'Located' : 'Located, +/- $acc m';
    }
    return switch (_currentGps['reason']) {
      'locating' => 'Locating',
      'timeout' => 'No location',
      'permission_denied' => 'Location not allowed',
      'location_off' => 'Location off',
      _ => 'No location',
    };
  }

  // ---------------------------------------------------------------------------
  // Lifecycle
  // ---------------------------------------------------------------------------

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _notificationStop = RecordingForegroundService.stopRequests.listen((_) {
      if (mounted && _isRecording) unawaited(_stopRecording(synthesize: true));
    });
    _pulseController = AnimationController(vsync: this, duration: const Duration(milliseconds: 1400));
    _initPermissionsAndGps();
    _initSpeech();
    _initSecurity();

    final visit = _visit;
    _consentConfirmed = visit.consentConfirmed;
    _consentAtUtc = visit.consentAtUtc;
    _consentRecord = visit.consent;
    _isSigned = visit.status != VisitStatus.inProgress;
    // A declined consent is kept on the visit, not treated as consent.
    if (_consentRecord?.declined ?? false) _consentConfirmed = false;
    _claimReady = visit.status.index >= VisitStatus.claimReady.index;
    _afterReady = visit.status.index > VisitStatus.claimReady.index ? visit.status : null;
    _submission = visit.submission;
    _claim = visit.claim;
    _transcriptController.text = visit.transcript;
    if (!widget.previewRecording && visit.liveRecording != null) {
      if (visit.transcript.trim().isEmpty) {
        unawaited(_clearCheckpoint());
      } else {
        _interrupted = visit.liveRecording;
      }
    }
    final saved = visit.encounter;
    if (saved != null) {
      _encounter = ClinicalEncounter.fromJson(saved);
      _signedAt = _encounter.signedAtUtc?.toLocal();
      _syncControllers();
    } else {
      _synthesizeEncounter();
    }
    // "Locating" resolves to "No location" instead of spinning forever.
    _locatingTimeout = Timer(const Duration(seconds: 15), () {
      if (mounted && !_hasFix && _currentGps['reason'] == 'locating') {
        setState(() => _currentGps = const {'available': false, 'reason': 'timeout'});
      }
    });
    if (!widget.previewRecording) {
      // Coverage and copay on the visit, checked once a day at most.
      unawaited(_eligibility.ensureFresh(widget.accountNumber, widget.visitNumber).then((_) {
        if (mounted) setState(() {});
      }).catchError((Object _) {}));
    }

    if (widget.previewRecording) {
      _consentConfirmed = true;
      _consentAtUtc = DateTime.now().toUtc();
      _isRecording = true;
      _recordSeconds = 263;
      _transcriptController.text = sampleConversations.values.first.split('\n').take(4).join('\n');
    }
  }

  Future<void> _initPermissionsAndGps() async {
    try {
      await SecurityAndBackgroundService.requestAppPermissions();
      await _refreshLocation();
    } catch (e) {
      debugPrint('Permission or location initialization failed: $e');
    }
  }

  /// Takes a fresh device fix. Called on open, when recording starts (so
  /// the visit is tagged where it happened), and from Session details.
  Future<void> _refreshLocation() async {
    final gps = await SecurityAndBackgroundService.getGpsCoordinates();
    if (!mounted) return;
    setState(() {
      // Keep a good earlier fix if a later attempt fails.
      if (gps['available'] == true || !_hasFix) _currentGps = gps;
      _gpsResolved = true;
    });
    if (gps['available'] == true) _applySavedPlace(gps);
  }

  /// A fix inside a saved place sets the visit's place of service, unless
  /// the clinician chose one by hand or the note already exists.
  void _applySavedPlace(Map<String, dynamic> gps) {
    final visit = _visitOrNull;
    if (visit == null || visit.posSource == 'manual' || visit.posSource == 'place' || _hasNote || widget.previewRecording) return;
    final place = matchSavedPlace(_repo.provider.savedPlaces, gps);
    if (place == null || place.placeOfService == visit.placeOfService) return;
    unawaited(_repo.updateVisit(widget.accountNumber, visit.copyWith(placeOfService: place.placeOfService, posSource: 'place')).then((_) {
      if (!mounted) return;
      setState(() {});
      _showMessage('At ${place.name}: place of service set to ${placeOfService(place.placeOfService).label}.', icon: Icons.place_outlined);
    }));
  }

  Future<void> _initSecurity() async {
    try {
      final secureSuccess = await SecurityAndBackgroundService.setScreenshotsBlocked(_repo.provider.blockScreenshots);
      final securityReport = await SecurityAndBackgroundService.checkSecurityPosture();
      if (!mounted) return;
      setState(() => _isFlagSecureActive = secureSuccess);
      if (securityReport['isTampered'] == true) {
        debugPrint('High-security alert: Device posture indicates root or debugger active.');
      }
    } catch (e) {
      debugPrint('Security initialization failed: $e');
    }
  }

  Future<bool> _initSpeech() async {
    if (_speechEnabled) return true;
    try {
      _speechEnabled = await _speech.initialize(onError: _onSpeechError, onStatus: _onSpeechStatus);
    } catch (e) {
      debugPrint('Speech init failed: $e');
      _speechEnabled = false;
    }
    return _speechEnabled;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!_isRecording) return;
    if (state == AppLifecycleState.resumed) {
      // A call or another app can take the microphone; the basic engine
      // does not restart by itself.
      if (!_isPaused && _engine == null && !_speech.isListening) unawaited(_listen());
    } else {
      unawaited(_saveCheckpoint(force: true));
    }
  }

  /// Saves the transcript so far and marks the recording as running.
  Future<void> _saveCheckpoint({bool force = false}) async {
    final visit = _visitOrNull;
    if (visit == null || widget.previewRecording || !_isRecording) return;
    final text = _transcriptController.text;
    if (!force && text == _checkpointedText) return;
    _checkpointedText = text;
    final now = DateTime.now().toUtc();
    await _repo.updateVisit(
      widget.accountNumber,
      visit.copyWith(
        transcript: text,
        liveRecording: RecordingCheckpoint(startedAtUtc: _recordingStartedUtc ?? now, savedAtUtc: now, seconds: _recordSeconds),
      ),
    );
  }

  /// The recording ended normally: keep the transcript, drop the marker.
  Future<void> _clearCheckpoint() async {
    _checkpointTimer?.cancel();
    _checkpointTimer = null;
    final visit = _visitOrNull;
    if (visit == null || widget.previewRecording || visit.liveRecording == null) return;
    await _repo.updateVisit(widget.accountNumber, visit.copyWith(transcript: _transcriptController.text, clearLiveRecording: true));
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    // Leaving the screen mid-recording: save what was captured. The marker
    // stays, so the visit offers to continue when it is opened again.
    if (_isRecording) unawaited(_saveCheckpoint(force: true));
    _checkpointTimer?.cancel();
    // Invalidate any in-flight synthesis so late responses are dropped.
    _synthesisGeneration++;
    _recordTimer?.cancel();
    _listenRestartTimer?.cancel();
    _gpsTrackTimer?.cancel();
    _locatingTimeout?.cancel();
    _detachLevel?.call();
    _micLevel.dispose();
    if (_speech.isListening) {
      unawaited(_speech.cancel().catchError((Object e) => debugPrint('Speech cancel on dispose failed: $e')));
    }
    unawaited(_engineSub?.cancel());
    unawaited(_engine?.stop().catchError((Object e) => ''));
    unawaited(_notificationStop?.cancel());
    if (_isRecording || _isBackgroundWakeLockActive || _foregroundServiceActive) {
      unawaited(RecordingForegroundService.stop());
      unawaited(SecurityAndBackgroundService.releaseBackgroundWakeLock());
    }
    _pulseController.dispose();
    _liveScroll.dispose();
    _transcriptController.dispose();
    for (final c in _soapControllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  // ---------------------------------------------------------------------------
  // Derived state
  // ---------------------------------------------------------------------------

  bool get _hasNote => _encounter.transcript.isNotEmpty || _encounter.rawTranscript.trim().isNotEmpty;

  _Phase get _phase {
    if (_isRecording) return _Phase.recording;
    if (_isProcessing) return _Phase.generating;
    return _hasNote ? _Phase.review : _Phase.ready;
  }

  int get _pendingOrders => _encounter.nextSteps.where((a) => !a.isCompleted).length;

  /// Facts about this visit that change how it is coded.
  CodingContext _codingContext() {
    final visit = _visit;
    final account = _account;
    return CodingContext(
      dateOfService: DateTime.tryParse(visit.dateOfService),
      placeOfService: visit.placeOfService,
      newPatient: !account.visits.any((v) => v.number < visit.number),
      sex: account.sex,
      age: account.ageOn(DateTime.tryParse(visit.dateOfService)),
      feeSchedule: _repo.provider.feeSchedule,
      priorDiagnosisCodes: {
        for (final v in account.visits)
          if (v.number < visit.number && v.claim != null)
            for (final d in v.claim!.billable) d.code,
      },
    );
  }

  /// Codes the visit from the conversation and keeps the note's code list in
  /// step with the claim (used by the FHIR export and the copied note).
  void _rebuildClaim() {
    final result = ClinicalCoder.code(turns: _encounter.transcript, vitals: _encounter.vitals, context: _codingContext());
    _claim = ClaimDraft(diagnoses: result.diagnoses, lines: result.lines, generatedAtUtc: DateTime.now().toUtc());
    _claimReady = false;
    _syncCodesFromClaim();
  }

  void _syncCodesFromClaim() {
    final claim = _claim;
    if (claim == null) return;
    _encounter = _encounter.copyWith(codes: [
      for (final d in claim.billable) MedicalCode(code: d.code, description: d.description, type: 'ICD10', rationale: d.evidence),
      for (final l in claim.lines) MedicalCode(code: l.code, description: l.description, type: 'CPT', rationale: l.evidence),
    ]);
  }

  VisitStatus get _status => _afterReady ?? (_claimReady ? VisitStatus.claimReady : (_isSigned ? VisitStatus.signed : VisitStatus.inProgress));

  /// Picks up status changes made by the claim service (send, outbox,
  /// status refresh) from the stored visit.
  void _reloadFromRepo() {
    final v = _visitOrNull;
    if (v == null) return;
    _submission = v.submission;
    _afterReady = v.status.index > VisitStatus.claimReady.index ? v.status : null;
    _claimReady = v.status.index >= VisitStatus.claimReady.index;
  }

  /// Saves the note, raw transcript, consent and claim into the visit.
  Future<void> _persist() async {
    final visit = _visitOrNull;
    if (visit == null || widget.previewRecording) return; // discarded, or a preview
    await _repo.updateVisit(
      widget.accountNumber,
      visit.copyWith(
        encounter: _hasNote ? _encounter.toJson() : null,
        transcript: _transcriptController.text,
        claim: _claim,
        clearClaim: _claim == null,
        status: _status,
        submission: _submission,
        consentConfirmed: _consentConfirmed,
        consentAtUtc: _consentAtUtc,
        consent: _consentRecord,
      ),
    );
  }

  /// Applies a claim change. With [undoLabel] (a removal or replacement) the
  /// snackbar offers Undo, which restores the claim as it was.
  void _onClaimChanged(ClaimDraft claim, {String? undoLabel}) {
    final before = _claim;
    if (before != null && before.codeSummary != claim.codeSummary) {
      unawaited(_record('Changed codes', detail: 'from ${before.codeSummary} to ${claim.codeSummary}'));
    }
    setState(() {
      _claim = claim;
      _claimReady = false;
      if (_afterReady == VisitStatus.rejected) _afterReady = null;
      _syncCodesFromClaim();
    });
    _persist();
    if (undoLabel != null && before != null) {
      _showMessage(
        undoLabel,
        icon: Icons.undo_rounded,
        action: SnackBarAction(
          label: 'Undo',
          onPressed: () {
            if (!mounted) return;
            setState(() {
              _claim = before;
              _claimReady = false;
              _syncCodesFromClaim();
            });
            _persist();
          },
        ),
      );
    }
  }

  void _onTransportChanged(AmbulanceTransport t) {
    final visit = _visitOrNull;
    if (visit == null) return;
    // The origin and destination modifier goes on every ambulance line.
    final claim = _claim;
    final mod = t.modifier;
    if (claim != null && mod != null) {
      final lines = [
        for (final l in claim.lines)
          isAmbulanceServiceCode(l.code) ? l.copyWith(modifiers: [mod, ...l.modifiers.where((m) => !isOriginDestinationModifier(m))].take(4).toList()) : l,
      ];
      _claim = claim.copyWith(lines: lines);
    }
    unawaited(_repo.updateVisit(widget.accountNumber, visit.copyWith(transport: t)).then((_) => _persist()));
    setState(() {
      _claimReady = false;
      _syncCodesFromClaim();
    });
  }

  void _onReferralChanged(ReferringProvider? referring, String priorAuth) {
    final visit = _visitOrNull;
    if (visit == null) return;
    final updated = visit.copyWith(referringProvider: referring, clearReferringProvider: referring == null, priorAuthNumber: priorAuth);
    unawaited(_repo.updateVisit(widget.accountNumber, updated).then((_) => _persist()));
    setState(() => _claimReady = false);
  }

  /// Saves the service facility on the visit. A saved place with that name
  /// and no address learns this one, so the next visit there fills it in.
  Future<void> _onFacilityChanged(ServiceFacility? facility) async {
    final visit = _visitOrNull;
    if (visit == null) return;
    await _repo.updateVisit(widget.accountNumber, visit.copyWith(serviceFacility: facility, clearServiceFacility: facility == null));
    final p = _repo.provider;
    if (facility != null && p.savedPlaces.any((sp) => sp.name == facility.name && sp.address == null)) {
      await _repo.saveProvider(p.copyWith(savedPlaces: [
        for (final sp in p.savedPlaces) sp.name == facility.name && sp.address == null ? sp.copyWith(address: facility.oneLine) : sp,
      ]));
    }
    await _persist();
    if (mounted) setState(() => _claimReady = false);
  }

  /// Runs a check's fix button. Fixes that change the claim offer Undo.
  Future<void> _onFix(IssueFix fix) async {
    switch (fix.kind) {
      case FixKind.signNote:
        await _reviewAndSign();
      case FixKind.editProvider:
        await Navigator.push(context, MaterialPageRoute<void>(builder: (_) => const ProviderProfileScreen()));
        if (mounted) setState(() {});
      case FixKind.editPatient:
      case FixKind.scanCard:
        await Navigator.push(
          context,
          MaterialPageRoute<void>(builder: (_) => ScanCardScreen(existingAccountNumber: widget.accountNumber, manualEntry: fix.kind == FixKind.editPatient)),
        );
        if (mounted) setState(() {});
      default:
        // Claim-level fixes (codes, modifiers, place of service, transport,
        // line edits) are handled inside the Claim tab.
        break;
    }
  }

  Future<void> _changePlaceOfService(String pos) async {
    await _repo.updateVisit(widget.accountNumber, _visit.copyWith(placeOfService: pos, posSource: 'manual'));
    if (!mounted) return;
    // Recode the visit-level services for the new setting; keep the diagnoses
    // and any manually added procedures.
    final recoded = ClinicalCoder.code(turns: _encounter.transcript, vitals: _encounter.vitals, context: _codingContext());
    final current = _claim;
    final keep = current == null ? <ServiceLine>[] : current.lines.where((l) => emSettingOf(l.code) == null && !l.code.startsWith('A04') && !l.code.startsWith('9301') && l.code != '93000').toList();
    final newVisitLines = recoded.lines.where((l) => emSettingOf(l.code) != null || l.code.startsWith('A04') || l.code.startsWith('930'));
    final base = current ?? ClaimDraft(diagnoses: recoded.diagnoses, lines: const [], generatedAtUtc: DateTime.now().toUtc());
    _onClaimChanged(reconcileClaim(base, lines: [...newVisitLines, ...keep], dateOfService: DateTime.tryParse(_visit.dateOfService)));
    _showMessage('Place of service set to ${placeOfService(pos).label}. Visit codes updated.', icon: Icons.place_outlined);
  }

  void _copyClaim() {
    final claim = _claim;
    if (claim == null) return;
    final issues = _issues(claim);
    final json = ClaimBuilder.build(account: _account, visit: _visit, provider: _repo.provider, claim: claim, issues: issues);
    PhiClipboard.copy(const JsonEncoder.withIndent('  ').convert(json));
    HapticFeedback.lightImpact();
    _showMessage('Claim copied as JSON (CMS-1500 and 837P fields). The clipboard clears in 60 seconds.', icon: Icons.data_object_rounded);
  }

  /// Builds the HIPAA 5010 837P file for this visit.
  Future<X12BuildResult?> _buildX12({required bool forSubmission}) async {
    final claim = _claim;
    if (claim == null) return null;
    final settings = Integrations.settings;
    final config = forSubmission
        ? await settings.submitterConfigForNextClaim()
        : (settings.submitterConfig ??
            const SubmitterConfig(submitterName: 'SOLIS', submitterId: 'SOLIS', isaSenderId: 'SOLIS', isaReceiverId: 'RECEIVER'));
    if (config == null) {
      _showMessage('Add your submitter details in Integrations before sending claims.', icon: Icons.settings_outlined);
      return null;
    }
    return Claim837PGenerator.build(claim: claim, account: _account, visit: _visit, provider: _repo.provider, config: config);
  }

  Future<void> _copyX12() async {
    final r = await _buildX12(forSubmission: false);
    if (r == null || !mounted) return;
    if (!r.ok) {
      await _showProblems('The 837P file cannot be built yet', r.errors);
      return;
    }
    PhiClipboard.copy(r.pretty ?? r.x12!);
    _showMessage('837P file copied (${r.transactionSegmentCount} segments). The clipboard clears in 60 seconds.', icon: Icons.description_outlined);
  }

  Future<void> _showProblems(String title, List<String> problems) => showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          icon: Icon(Icons.error_outline_rounded, color: Theme.of(ctx).colorScheme.error, size: 32),
          title: Text(title, textAlign: TextAlign.center),
          content: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [for (final p in problems) Padding(padding: const EdgeInsets.symmetric(vertical: 4), child: Text(p))],
            ),
          ),
          actions: [FilledButton(onPressed: () => Navigator.pop(ctx), child: const Text('OK'))],
        ),
      );

  /// Adds [action] to the visit's audit trail; with [confirmCodes] also
  /// records the clinician's confirmation of the current codes.
  Future<void> _record(String action, {String detail = '', bool confirmCodes = false}) async {
    final visit = _visitOrNull;
    if (visit == null || widget.previewRecording) return;
    final by = _repo.provider.displayName;
    final claim = _claim;
    var updated = visit.withAudit(by, action, detail: detail);
    if (confirmCodes && claim != null) {
      updated = updated.copyWith(
        codeConfirmation: CodeConfirmation(atUtc: DateTime.now().toUtc(), by: by, fingerprint: claim.codeFingerprint, codes: claim.codeSummary),
      );
    }
    await _repo.updateVisit(widget.accountNumber, updated);
  }

  /// Asks the clinician to confirm the E/M level and codes when the current
  /// claim has not been confirmed (or changed since). True when confirmed.
  Future<bool> _ensureCodesConfirmed() async {
    final claim = _claim;
    if (claim == null) return false;
    if (_visit.codesConfirmedFor(claim)) return true;
    var ticked = false;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          key: const Key('confirm_codes_dialog'),
          icon: const Icon(Icons.fact_check_outlined, size: 32),
          title: const Text('Confirm the codes', textAlign: TextAlign.center),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final l in claim.lines) Text('${[l.code, ...l.modifiers].join('-')}  ${l.description}'),
              for (final d in claim.billable) Text('${d.code}  ${d.description}'),
              const SizedBox(height: 8),
              CheckboxListTile(
                key: const Key('confirm_codes'),
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                value: ticked,
                onChanged: (v) => setLocal(() => ticked = v ?? false),
                title: Text(SignAndSendSheet.confirmText(claim.emLine?.code)),
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            FilledButton(key: const Key('confirm_codes_ok'), onPressed: ticked ? () => Navigator.pop(ctx, true) : null, child: const Text('Confirm')),
          ],
        ),
      ),
    );
    if (ok != true || !mounted) return false;
    await _record('Confirmed E/M level and codes', detail: claim.codeSummary, confirmCodes: true);
    return true;
  }

  /// True from the tap on Send until the send has finished, so a double tap
  /// (or a tap while the confirm dialog is opening) cannot send twice.
  bool _sendInFlight = false;

  /// Sends the claim to the clearinghouse after the physician confirms.
  Future<void> _submitClaim() async {
    if (_sendInFlight || _submitting) return;
    _sendInFlight = true;
    try {
      await _submitClaimOnce();
    } finally {
      _sendInFlight = false;
    }
  }

  /// Billing a real claim needs SOLIS Pro; notes and test claims never do.
  Future<bool> _proForClaim() async {
    if (_claims.isConnected && _claims.isTest) return true;
    return ensurePro(context);
  }

  Future<void> _submitClaimOnce() async {
    if (!await _ensureCodesConfirmed() || !mounted) return;
    if (!await _proForClaim() || !mounted) return;
    if (!_claims.isConnected) {
      _copyClaim();
      return;
    }
    final test = _claims.isTest;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: const Icon(Icons.outbox_outlined, size: 32),
        title: Text(test ? 'Send test claim?' : 'Send claim to ${_account.insurance?.payerName ?? 'the payer'}?', textAlign: TextAlign.center),
        content: Text(
          '${ClaimBuilder.claimId(_account, _visit)}, total \$${_claim!.totalCharge.toStringAsFixed(2)}. '
          '${test ? 'Test claims are checked by the clearinghouse but not paid.' : 'The payer will adjudicate this claim.'}',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Send')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await _sendNow();
  }

  /// Sends through the claim service (same checks, outbox and idempotency
  /// key as the Billing tab's batch send) and reports the outcome.
  Future<void> _sendNow({ClaimFrequency frequency = ClaimFrequency.original}) async {
    await _persist();
    setState(() => _submitting = true);
    try {
      final r = frequency == ClaimFrequency.original
          ? await _claims.send(widget.accountNumber, widget.visitNumber)
          : await _claims.sendReplacement(widget.accountNumber, widget.visitNumber, frequency);
      if (!mounted) return;
      setState(_reloadFromRepo);
      switch (r.status) {
        case SendStatus.accepted:
          HapticFeedback.mediumImpact();
          final what = switch (frequency) {
            ClaimFrequency.original => 'Claim',
            ClaimFrequency.replacement => 'Corrected claim',
            ClaimFrequency.voided => 'Void request',
          };
          _showMessage('$what accepted by the clearinghouse${r.testMode ? ' (test)' : ''}.', icon: Icons.outbox_outlined);
        case SendStatus.queued:
          _showMessage('No connection. The claim is queued and sends when the connection is back.', icon: Icons.schedule_send_outlined);
        case SendStatus.rejected:
          await _showProblems('The clearinghouse rejected the claim', r.problems);
        case SendStatus.blocked:
          await _showProblems('Fix these before sending', r.problems);
        case SendStatus.failed:
          _showMessage('Not sent: ${r.problems.isEmpty ? 'unknown error' : r.problems.first}', icon: Icons.cloud_off_outlined);
      }
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  /// Corrected (frequency 7) or void (frequency 8) claim for a claim the
  /// payer already has. The current claim on this visit is what is sent.
  Future<void> _replaceClaim(ClaimFrequency frequency) async {
    final icn = _visit.submission?['payerClaimNumber'] ?? _visit.submission?['replacesPayerClaimNumber'];
    final voiding = frequency == ClaimFrequency.voided;
    final payer = _account.insurance?.payerName ?? 'the payer';
    final total = _claim!.totalCharge.toStringAsFixed(2);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: Icon(voiding ? Icons.block_rounded : Icons.edit_note_rounded, size: 32),
        title: Text(voiding ? 'Void this claim?' : 'Send a corrected claim?', textAlign: TextAlign.center),
        content: Text(voiding
            ? 'Asks $payer to cancel claim $icn. Any payment already made will be taken back.'
            : 'Replaces claim $icn at $payer with the claim as it is now, total \$$total.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(voiding ? 'Void claim' : 'Send corrected claim')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await _sendNow(frequency: frequency);
  }

  /// Asks the payer for this claim's status (276/277), matched by the
  /// claim's own control number, and records paid, denied or rejected.
  Future<void> _checkClaimStatus() async {
    setState(() => _submitting = true);
    try {
      final r = await _claims.refreshStatus(widget.accountNumber, widget.visitNumber);
      if (!mounted) return;
      setState(_reloadFromRepo);
      _showMessage(r.message, icon: r.updated ? Icons.fact_check_outlined : Icons.hourglass_empty_rounded);
    } catch (e) {
      if (mounted) _showMessage('Could not reach the clearinghouse: $e', icon: Icons.cloud_off_outlined);
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  /// Claim checks for this visit, in the current mode.
  List<ClaimIssue> _issues(ClaimDraft claim, {bool? signed}) => ClaimScrubber.check(
        claim: claim,
        account: _account,
        visit: _visit,
        provider: _repo.provider,
        noteSigned: signed ?? _isSigned,
        demoMode: _repo.demoMode,
      );

  Widget? _submissionHeader(BuildContext context) {
    final s = _submission;
    if (s == null) return null;
    final status = _afterReady;
    final (color, icon, title) = switch (status) {
      VisitStatus.paid => (SolisTheme.success, Icons.payments_outlined, 'Paid${s['paidAmount'] != null ? ': \$${s['paidAmount']}' : ''}'),
      VisitStatus.denied => (SolisTheme.danger, Icons.block_rounded, 'Denied by the payer'),
      VisitStatus.rejected => (SolisTheme.danger, Icons.error_outline_rounded, 'Rejected before reaching the payer'),
      VisitStatus.queued => (SolisTheme.warning, Icons.schedule_send_outlined, 'Queued, waiting for a connection'),
      _ => (SolisTheme.info, Icons.outbox_outlined, 'Submitted${s['testMode'] == true ? ' as a test claim' : ''}'),
    };
    if (status == VisitStatus.queued) {
      return NoteBanner(
        icon: icon,
        title: title,
        message: 'Sends automatically with the same claim key when SOLIS reaches the clearinghouse. '
            'Attempts: ${s['attempts'] ?? 1}.',
        color: color,
      );
    }
    final lines = [
      if (s['statusExplanation'] != null)
        'Latest status: ${s['statusExplanation']}'
      else if (s['lastStatus'] != null)
        'Latest status: ${s['lastStatus']}',
      if (s['payerClaimNumber'] != null) 'Payer claim number ${s['payerClaimNumber']}',
      if ((s['errors'] as List?)?.isNotEmpty == true) ...(s['errors'] as List).map((e) => '$e'),
      if (s['correlationId'] != null) 'Clearinghouse reference ${s['correlationId']}',
      ...claimHistoryLines(s),
    ];
    final banner = NoteBanner(icon: icon, title: title, message: lines.isEmpty ? 'Waiting for the payer.' : lines.join('\n'), color: color);
    if (status != VisitStatus.rejected && status != VisitStatus.denied) return banner;
    // One tap to the place that fixes what the rejection names.
    final fixes = RejectionFixes.forMessages([
      ...((s['errors'] as List?) ?? const []).map((e) => '$e'),
      if (s['statusExplanation'] != null) '${s['statusExplanation']}',
      if (s['lastStatus'] != null) '${s['lastStatus']}',
    ]);
    if (fixes.isEmpty) return banner;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        banner,
        const SizedBox(height: 8),
        Wrap(
          key: const Key('rejection_fixes'),
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final f in fixes)
              OutlinedButton.icon(
                icon: Icon(switch (f.kind) {
                  FixKind.scanCard => Icons.document_scanner_outlined,
                  FixKind.editProvider => Icons.badge_outlined,
                  FixKind.editPatient => Icons.person_outline_rounded,
                  _ => Icons.receipt_long_outlined,
                }),
                label: Text(f.label),
                onPressed: () {
                  if (f.kind == FixKind.editLine) {
                    setState(() => _reviewTab = 3);
                  } else {
                    unawaited(_onFix(f));
                  }
                },
              ),
          ],
        ),
      ],
    );
  }

  Future<void> _markClaimReady() async {
    if (!await _ensureCodesConfirmed() || !mounted) return;
    if (!await _proForClaim() || !mounted) return;
    setState(() => _claimReady = true);
    await _persist();
    if (!mounted) return;
    HapticFeedback.mediumImpact();
    _showMessage('Claim marked ready to bill.', icon: Icons.task_alt_rounded);
  }

  // ---------------------------------------------------------------------------
  // Note synthesis and archival
  // ---------------------------------------------------------------------------

  void _syncControllers() {
    _soapControllers['subjective']!.text = _encounter.subjective;
    _soapControllers['objective']!.text = _encounter.objective;
    _soapControllers['assessment']!.text = _encounter.assessment;
    _soapControllers['plan']!.text = _encounter.plan;
  }

  Future<void> _synthesizeEncounter() async {
    final generation = ++_synthesisGeneration;
    bool isStale() => !mounted || generation != _synthesisGeneration;

    if (_transcriptController.text.trim().isEmpty) {
      final blankEncounter = ClinicalEncounter(
        id: 'ENC-${DateTime.now().millisecondsSinceEpoch}',
        patientName: _patientName,
        mrn: _mrn,
        ageGender: _ageGender,
        attendingPhysician: _attending,
        date: _visit.dateOfService,
        vitals: const [],
        transcript: const [],
        subjective: '',
        objective: '',
        assessment: '',
        plan: '',
        codes: const [],
        nextSteps: const [],
        latencyMs: 5,
        rawTranscript: '',
        gpsCoordinates: _currentGps,
      );
      if (mounted) {
        setState(() {
          _encounter = blankEncounter;
          _isProcessing = false;
          _syncControllers();
        });
      }
      return;
    }

    if (!mounted) return;
    setState(() {
      _isProcessing = true;
      _editing.clear();
    });

    // The conversation is always parsed on the device: speaker turns,
    // vitals and the claim come from deterministic rules that are checked
    // against the official code sets.
    final local = LocalClinicalEngine.synthesizeOnDevice(
      rawSpeech: _transcriptController.text,
      patientName: _patientName,
      mrn: _mrn,
      ageGender: _ageGender,
      attending: _attending,
      context: _codingContext(),
    ).copyWith(gpsCoordinates: _currentGps, date: _visit.dateOfService);
    _pendingLocal = local;

    // Cloud mode: Claude writes the note text through the SOLIS server.
    CloudNote? cloud;
    final backend = SolisBackend.instance;
    if (!_isOffline && backend.isConfigured) {
      final stopwatch = Stopwatch()..start();
      try {
        final ctx = _codingContext();
        cloud = await backend.writeNote(
          transcript: _transcriptController.text,
          age: ctx.age,
          sex: _account.sex.name,
          placeOfService: placeOfService(_visit.placeOfService).name,
          visitType: '${ctx.newPatient ? 'New' : 'Established'} patient, ${_visitType.toLowerCase()}',
        );
        if (cloud.isEmpty) cloud = null;
      } on BackendException catch (e) {
        if (!isStale()) _showMessage('${e.message}. The note was written on this phone instead.', icon: Icons.smartphone_outlined);
      }
      stopwatch.stop();
      if (isStale()) return;
      if (cloud != null) _cloudLatencyMs = stopwatch.elapsedMilliseconds;
    }
    if (isStale()) return;

    final encounter = cloud == null
        ? local
        : local.copyWith(
            subjective: cloud.subjective.join('\n'),
            objective: cloud.objective.join('\n'),
            assessment: cloud.assessment.join('\n'),
            plan: cloud.plan.join('\n'),
            vitals: cloud.vitals.isEmpty
                ? local.vitals
                : [for (final v in cloud.vitals) VitalSign(label: v.name, value: v.display)],
            latencyMs: _cloudLatencyMs,
          );

    setState(() {
      _encounter = encounter;
      _pendingLocal = null;
      _isProcessing = false;
      _syncControllers();
      _rebuildClaim();
      if (cloud != null) _addAiDiagnoses(cloud.diagnoses);
    });
    _persist();
  }

  int _cloudLatencyMs = 0;

  /// The on-device draft of the note being written, while the cloud model
  /// works. Lets the clinician stop waiting.
  ClinicalEncounter? _pendingLocal;

  /// Stops waiting for the cloud model and uses the on-device note now.
  /// A cloud answer that arrives later is ignored.
  void _useOnDeviceNow() {
    final local = _pendingLocal;
    if (local == null || !_isProcessing) return;
    _synthesisGeneration++;
    setState(() {
      _encounter = local;
      _pendingLocal = null;
      _isProcessing = false;
      _syncControllers();
      _rebuildClaim();
    });
    _persist();
    _showMessage('Using the note written on this phone.', icon: Icons.smartphone_outlined);
  }

  /// Diagnoses Claude found that the rules did not, offered on the claim for
  /// the clinician to confirm. Never billed until confirmed, and only codes
  /// that exist and are billable in the edition for the date of service.
  void _addAiDiagnoses(List<CloudDiagnosis> found) {
    final claim = _claim;
    if (claim == null) return;
    final icd = ReferenceData.icdFor(DateTime.tryParse(_visit.dateOfService) ?? DateTime.now());
    final have = {for (final d in claim.diagnoses) d.code};
    final added = <ClaimDiagnosis>[];
    for (final d in found) {
      final code = d.icd10Candidate;
      if (code == null || code.isEmpty || have.contains(code)) continue;
      if (icd != null && !icd.isBillable(code)) continue;
      have.add(code);
      added.add(ClaimDiagnosis(
        code: code,
        description: icd?.description(code) ?? d.description,
        source: d.confirmed ? DxSource.physicianConfirmed : DxSource.patientReported,
        status: DxStatus.uncertain,
        evidence: d.evidence,
        note: 'Suggested by the AI note writer. Confirm if it applies.',
      ));
    }
    if (added.isEmpty) return;
    _claim = claim.copyWith(diagnoses: [...claim.diagnoses, ...added]);
    _syncCodesFromClaim();
  }

  // ---------------------------------------------------------------------------
  // Recording
  // ---------------------------------------------------------------------------

  void _showMessage(String message, {IconData icon = Icons.info_outline_rounded, SnackBarAction? action}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          action: action,
          content: Row(
            children: [
              Icon(icon, size: 20, color: Theme.of(context).snackBarTheme.contentTextStyle?.color),
              const SizedBox(width: 12),
              Expanded(child: Text(message)),
            ],
          ),
        ),
      );
  }

  Future<void> _onRecordPressed() async {
    if (_isTogglingRecording) return;
    _isTogglingRecording = true;
    try {
      if (!_consentConfirmed) {
        final agreed = await _askForConsent();
        if (!agreed || !mounted) return;
      }
      // Android 13+: the recording notification needs this; asked once, and
      // a denial does not stop the recording.
      if (!widget.previewRecording) await RecordingForegroundService.ensureNotificationPermission();
      if (!mounted) return;
      await _startRecording();
    } finally {
      _isTogglingRecording = false;
    }
  }

  Future<void> _startRecording() async {
    final picked = widget.previewRecording
        ? null
        : SpeechEngines.pick(onDevice: _isOffline, settings: CaptureSettings(noiseSuppression: _noiseSuppression, language: _language));
    final available = picked != null || await _initSpeech();
    if (!mounted) return;
    if (!available) {
      _showMessage(
        'Speech recognition is not available on this device. You can type the conversation instead.',
        icon: Icons.mic_off_outlined,
        action: SnackBarAction(label: 'Type', onPressed: _openTypeSheet),
      );
      return;
    }

    // The microphone foreground service keeps capture going with the screen
    // off and holds the wake lock; without it (iOS, or it could not start)
    // this screen holds the wake lock itself.
    final foreground = !widget.previewRecording && await RecordingForegroundService.start();
    final wakeLockAcquired = foreground || await SecurityAndBackgroundService.acquireBackgroundWakeLock();
    if (!mounted) {
      unawaited(RecordingForegroundService.stop());
      unawaited(SecurityAndBackgroundService.releaseBackgroundWakeLock());
      return;
    }
    _foregroundServiceActive = foreground;

    HapticFeedback.heavyImpact();
    unawaited(_refreshLocation().then((_) => _notePickup()));
    _committedTranscript = _transcriptController.text.trim();
    setState(() {
      _isRecording = true;
      _isPaused = false;
      _isBackgroundWakeLockActive = wakeLockAcquired;
      _recordSeconds = 0;
      _noSound = false;
      _micLevel.value = 0;
    });
    _silentSeconds = 0;
    _pulseController.repeat();
    _startGpsTrack();
    _recordingStartedUtc = DateTime.now().toUtc();
    _interrupted = null;
    _checkpointedText = '';
    unawaited(_saveCheckpoint(force: true));
    _checkpointTimer?.cancel();
    _checkpointTimer = Timer.periodic(_checkpointEvery, (_) => unawaited(_saveCheckpoint()));

    _recordTimer?.cancel();
    _recordTimer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted || !_isRecording) {
        t.cancel();
        return;
      }
      if (!_isPaused) {
        setState(() => _recordSeconds++);
        _checkForSilence();
      }
    });

    if (picked != null) {
      _startEngine(picked.$1, picked.$2);
    } else {
      _engineKind = SpeechEngine.basic;
      await _listen();
    }
  }

  void _startEngine(TranscriptionProvider engine, SpeechEngine kind) {
    _engine = engine;
    _engineKind = kind;
    final before = _committedTranscript;
    _attachLevel(engine is AudioLevelSource ? (engine as AudioLevelSource).audioLevel : null);
    _engineSub = engine.start().listen((u) {
      if (!mounted || !identical(_engine, engine)) return;
      if (u.status == TranscriptionStatus.failed) {
        unawaited(_fallBackToBasic(u.error));
        return;
      }
      if (u.transcript.isEmpty && u.interim.isEmpty) return;
      _heardSomething();
      if (u.transcript.isEmpty) return;
      setState(() => _transcriptController.text = _joinTranscript(before, u.transcript));
      _scrollLiveToEnd();
    });
  }

  /// Forwards the engine's microphone level to the meter.
  void _attachLevel(ValueListenable<double>? source) {
    _detachLevel?.call();
    _detachLevel = null;
    if (source == null) return;
    void forward() => _onLevel(source.value);
    source.addListener(forward);
    _detachLevel = () => source.removeListener(forward);
  }

  void _onLevel(double level) {
    if (!mounted) return;
    _micLevel.value = level;
    if (level >= _noiseFloor) _heardSomething();
  }

  /// Sound above the noise floor, or new words: the microphone works.
  void _heardSomething() {
    _silentSeconds = 0;
    if (_noSound && mounted) setState(() => _noSound = false);
  }

  /// Warns once when nothing has been heard for [_noSoundSeconds] seconds, so
  /// a muted or failed microphone is found now, not after the visit.
  void _checkForSilence() {
    if (widget.previewRecording) return;
    _silentSeconds++;
    if (_noSound || _silentSeconds < _noSoundSeconds) return;
    setState(() => _noSound = true);
    HapticFeedback.heavyImpact();
    _showMessage('SOLIS hears nothing. Check the microphone.', icon: Icons.mic_off_outlined);
  }

  // --- Ambulance transport from location fixes ------------------------------

  bool get _isAmbulance => isAmbulancePos(_visitOrNull?.placeOfService ?? '');

  /// Samples the location every 15 s while recording an ambulance visit;
  /// the fixes are summed into loaded miles.
  void _startGpsTrack() {
    _gpsTrackTimer?.cancel();
    if (!_isAmbulance || widget.previewRecording) return;
    _gpsTrack.clear();
    if (_hasFix) _gpsTrack.add(Map<String, dynamic>.from(_currentGps));
    _gpsTrackTimer = Timer.periodic(const Duration(seconds: 15), (_) async {
      if (!mounted || !_isRecording) return;
      final fix = await SecurityAndBackgroundService.getGpsCoordinates(timeoutMs: 8000);
      if (fix['available'] == true) _gpsTrack.add(fix);
    });
  }

  /// Pick-up address from the fix at record start, if the crew has not
  /// entered one.
  void _notePickup() {
    if (!_isAmbulance || !mounted) return;
    final addr = TransportAddress.fromGps(_currentGps);
    final t = _visit.transport ?? const AmbulanceTransport();
    if (addr == null || !t.pickup.isEmpty) return;
    unawaited(_repo.updateVisit(widget.accountNumber, _visit.copyWith(transport: t.copyWith(pickup: addr))));
  }

  /// At Finish: drop-off from the last fix and loaded miles from the track,
  /// rounded up to a tenth of a mile. Values the crew typed are kept.
  Future<void> _finishTransport() async {
    _gpsTrackTimer?.cancel();
    if (!_isAmbulance || widget.previewRecording) return;
    final fix = await SecurityAndBackgroundService.getGpsCoordinates(timeoutMs: 8000);
    if (!mounted) return;
    if (fix['available'] == true) {
      _gpsTrack.add(fix);
      setState(() => _currentGps = fix);
    }
    final visit = _visitOrNull;
    if (visit == null) return;
    var t = visit.transport ?? const AmbulanceTransport();
    final drop = TransportAddress.fromGps(fix);
    if (drop != null && t.dropoff.isEmpty) t = t.copyWith(dropoff: drop);
    final miles = trackMiles(_gpsTrack);
    if (miles > 0) {
      final rounded = roundUpTenth(miles);
      t = t.copyWith(gpsMiles: rounded);
      if (t.loadedMiles == null) t = t.copyWith(loadedMiles: rounded, milesSource: 'gps');
    }
    await _repo.updateVisit(widget.accountNumber, visit.copyWith(transport: t));
  }

  /// The voice engine failed (network, key, model). Keep what it captured
  /// and continue with Android speech recognition so the visit is not lost.
  Future<void> _fallBackToBasic(String? reason) async {
    final engine = _engine;
    _engine = null;
    await _engineSub?.cancel();
    _engineSub = null;
    if (engine != null) {
      try {
        await engine.stop();
      } catch (_) {}
    }
    if (!mounted) return;
    _committedTranscript = _transcriptController.text.trim();
    _engineKind = SpeechEngine.basic;
    _attachLevel(null);
    HapticFeedback.heavyImpact();
    _showMessage('${reason ?? 'Voice separation stopped'}. Recording continues with basic recognition.', icon: Icons.mic_none_rounded);
    if (_isRecording && await _initSpeech()) await _listen();
  }

  /// Stops the voice engine and keeps its final labeled transcript.
  Future<void> _stopEngine() async {
    final engine = _engine;
    if (engine == null) return;
    _engine = null;
    final before = _committedTranscript;
    String last = '';
    try {
      last = await engine.stop();
    } catch (e) {
      debugPrint('Voice engine stop failed: $e');
    }
    await _engineSub?.cancel();
    _engineSub = null;
    if (mounted && last.trim().isNotEmpty) {
      _transcriptController.text = _joinTranscript(before, last);
    }
  }

  Future<void> _listen() async {
    if (!mounted || !_isRecording || _isPaused || !_speechEnabled) return;
    final session = ++_listenSession;
    try {
      await _speech.listen(
        onResult: (result) => _onSpeechResult(result, session),
        // Android reports the input level in dB (about -2 to 10).
        onSoundLevelChange: (db) => _onLevel(((db + 2) / 12).clamp(0.0, 1.0)),
        listenOptions: stt.SpeechListenOptions(
          partialResults: true,
          cancelOnError: false,
          listenMode: stt.ListenMode.dictation,
          listenFor: const Duration(minutes: 20),
          pauseFor: const Duration(seconds: 8),
          localeId: _language.androidLocale,
        ),
      );
    } catch (e) {
      debugPrint('Error starting speech listen: $e');
    }
  }

  void _onSpeechResult(SpeechRecognitionResult result, int session) {
    if (!mounted || !_isRecording || session <= _committedSession) return;
    if (result.recognizedWords.trim().isNotEmpty) _heardSomething();
    setState(() {
      _transcriptController.text = _joinTranscript(_committedTranscript, result.recognizedWords);
    });
    if (result.finalResult) _commitSession(session);
    _scrollLiveToEnd();
  }

  void _onSpeechStatus(String status) {
    debugPrint('Speech status: $status');
    if (status != 'done' && status != 'notListening') return;
    _commitSession(_listenSession);
    // The platform ended the session (silence timeout). Keep listening while
    // the doctor has not paused or stopped.
    if (mounted && _isRecording && !_isPaused) {
      _listenRestartTimer?.cancel();
      _listenRestartTimer = Timer(const Duration(milliseconds: 350), _listen);
    }
  }

  void _onSpeechError(dynamic err) {
    debugPrint('Speech error: $err');
  }

  void _commitSession(int session) {
    if (session <= _committedSession) return;
    _committedSession = session;
    _committedTranscript = _transcriptController.text.trim();
  }

  static String _joinTranscript(String committed, String live) {
    if (live.trim().isEmpty) return committed;
    if (committed.isEmpty) return live.trim();
    return '$committed\n${live.trim()}';
  }

  void _scrollLiveToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_liveScroll.hasClients) {
        _liveScroll.animateTo(
          _liveScroll.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Future<void> _togglePause() async {
    if (!_isRecording) return;
    HapticFeedback.selectionClick();
    if (_isPaused) {
      setState(() {
        _isPaused = false;
        _noSound = false;
      });
      _silentSeconds = 0;
      _pulseController.repeat();
      if (_engine != null) {
        await _engine!.resume();
      } else {
        await _listen();
      }
    } else {
      setState(() => _isPaused = true);
      _micLevel.value = 0;
      _pulseController.stop();
      _listenRestartTimer?.cancel();
      if (_engine != null) {
        await _engine!.pause();
        return;
      }
      if (_speech.isListening) {
        try {
          await _speech.stop();
        } catch (e) {
          debugPrint('Error pausing speech: $e');
        }
      }
      _commitSession(_listenSession);
    }
  }

  /// Stops capture and releases the wake lock. When [synthesize] is false the
  /// captured text is left untouched (used by Discard, which clears it).
  Future<void> _stopRecording({required bool synthesize}) async {
    if (_isTogglingRecording && synthesize) return;
    _isTogglingRecording = true;
    try {
      _recordTimer?.cancel();
      _recordTimer = null;
      _listenRestartTimer?.cancel();
      _pulseController.stop();
      _attachLevel(null);
      _micLevel.value = 0;

      // Flip UI state first so late speech callbacks are ignored immediately.
      if (mounted) {
        setState(() {
          _isRecording = false;
          _isPaused = false;
          _isBackgroundWakeLockActive = false;
        });
      }
      HapticFeedback.mediumImpact();

      _foregroundServiceActive = false;
      await RecordingForegroundService.stop();
      await SecurityAndBackgroundService.releaseBackgroundWakeLock();
      // The on-device engine runs a final speaker pass on stop, which can
      // take a few seconds; show the note as in progress meanwhile.
      if (_engine != null && synthesize && mounted) setState(() => _isProcessing = true);
      await _stopEngine();
      if (_speech.isListening) {
        try {
          await _speech.stop();
        } catch (e) {
          debugPrint('Error stopping speech listen: $e');
        }
      }
      _commitSession(_listenSession);
      await _clearCheckpoint();
      if (!mounted) return;
      if (!synthesize) {
        _gpsTrackTimer?.cancel();
        return;
      }
      await _finishTransport();
      if (!mounted) return;

      if (_transcriptController.text.trim().isNotEmpty) {
        setState(() => _reviewTab = 0);
        unawaited(_synthesizeEncounter());
      } else {
        _showMessage('Nothing was captured. Check the microphone, or type the conversation instead.', icon: Icons.mic_none_rounded);
      }
    } finally {
      _isTogglingRecording = false;
    }
  }

  // ---------------------------------------------------------------------------
  // Encounter actions
  // ---------------------------------------------------------------------------

  static const _consentScripts = {
    'en': 'This visit will be recorded to help your doctor write your note. The recording is not part of your medical record and is deleted after the note is written. You can ask to pause or stop at any time, and saying no does not change your care.',
    'es': 'Esta consulta se grabará para ayudar a su médico a escribir su nota. La grabación no forma parte de su expediente médico y se borra después de escribir la nota. Puede pedir que se pause o se detenga en cualquier momento, y decir que no, no cambia su atención.',
  };

  /// Consent on the go: the script in the patient's language, then either
  /// verbal agreement confirmed by the clinician, or the patient signing on
  /// the phone. Saved with time and location on the visit.
  Future<bool> _askForConsent() async {
    // The language used at this patient's last visit, so a Spanish speaker
    // is not shown English first every time.
    var language = 'en';
    for (final v in [..._account.visits]..sort((a, b) => b.number.compareTo(a.number))) {
      final l = v.consent?.language;
      if (v.number != widget.visitNumber && l != null && _consentScripts.containsKey(l)) {
        language = l;
        break;
      }
    }
    var signing = false;
    List<List<double>> strokes = const [];
    final signer = TextEditingController(text: _patientName);
    var relationship = 'self';

    final record = await showModalBottomSheet<ConsentRecord?>(
      context: context,
      isScrollControlled: true,
      // A downward pen stroke must never close the sheet and lose the
      // signature; the sheet has explicit buttons for every way out.
      enableDrag: false,
      isDismissible: false,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) {
          final theme = Theme.of(ctx);
          final cs = theme.colorScheme;
          final hasSignature = strokes.where((p) => p[0] >= 0).length > 8;
          return Padding(
            padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(ctx).bottom),
            child: SafeArea(
              child: SingleChildScrollView(
                // While signing, strokes on the pad must not scroll the sheet.
                physics: signing ? const NeverScrollableScrollPhysics() : null,
                padding: const EdgeInsets.fromLTRB(24, 16, 24, 16),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Icon(Icons.record_voice_over_outlined, size: 32, color: cs.primary),
                    const SizedBox(height: 12),
                    Text('Ask for consent to record', textAlign: TextAlign.center, style: theme.textTheme.titleLarge),
                    const SizedBox(height: 12),
                    SegmentedButton<String>(
                      showSelectedIcon: false,
                      segments: const [
                        ButtonSegment(value: 'en', label: Text('English')),
                        ButtonSegment(value: 'es', label: Text('Español')),
                      ],
                      selected: {language},
                      onSelectionChanged: (v) => setSheet(() => language = v.first),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      _consentScripts[language]!,
                      style: theme.textTheme.bodyLarge?.copyWith(color: cs.onSurface),
                    ),
                    const SizedBox(height: 20),
                    if (!signing) ...[
                      FilledButton.icon(
                        onPressed: () => Navigator.pop(
                          ctx,
                          ConsentRecord(
                            method: 'verbal',
                            atUtc: DateTime.now().toUtc(),
                            language: language,
                            location: _hasFix ? Map<String, dynamic>.from(_currentGps) : null,
                          ),
                        ),
                        icon: const Icon(Icons.check_rounded),
                        label: const Text('Patient agreed, start recording'),
                      ),
                      const SizedBox(height: 8),
                      OutlinedButton.icon(
                        onPressed: () => setSheet(() => signing = true),
                        icon: const Icon(Icons.draw_outlined),
                        label: const Text('Patient signs on screen'),
                      ),
                      const SizedBox(height: 8),
                      TextButton(
                        onPressed: () => Navigator.pop(
                          ctx,
                          ConsentRecord(
                            method: 'declined',
                            atUtc: DateTime.now().toUtc(),
                            language: language,
                            location: _hasFix ? Map<String, dynamic>.from(_currentGps) : null,
                          ),
                        ),
                        child: const Text('Patient declined'),
                      ),
                    ] else ...[
                      SignaturePad(onChanged: (s) => setSheet(() => strokes = s)),
                      const SizedBox(height: 8),
                      TextField(
                        controller: signer,
                        textCapitalization: TextCapitalization.words,
                        decoration: const InputDecoration(labelText: 'Signed by'),
                      ),
                      const SizedBox(height: 12),
                      DropdownButtonFormField<String>(
                        initialValue: relationship,
                        decoration: const InputDecoration(labelText: 'Relationship to patient'),
                        items: const [
                          DropdownMenuItem(value: 'self', child: Text('Patient')),
                          DropdownMenuItem(value: 'parent', child: Text('Parent')),
                          DropdownMenuItem(value: 'guardian', child: Text('Legal guardian')),
                          DropdownMenuItem(value: 'representative', child: Text('Authorized representative')),
                        ],
                        onChanged: (v) => setSheet(() => relationship = v ?? 'self'),
                      ),
                      const SizedBox(height: 16),
                      FilledButton.icon(
                        onPressed: !hasSignature || signer.text.trim().isEmpty
                            ? null
                            : () => Navigator.pop(
                                  ctx,
                                  ConsentRecord(
                                    method: 'signature',
                                    atUtc: DateTime.now().toUtc(),
                                    signedBy: signer.text.trim(),
                                    relationship: relationship,
                                    signature: strokes,
                                    language: language,
                                    location: _hasFix ? Map<String, dynamic>.from(_currentGps) : null,
                                  ),
                                ),
                        icon: const Icon(Icons.check_rounded),
                        label: const Text('Save signature and start'),
                      ),
                      TextButton(onPressed: () => setSheet(() => signing = false), child: const Text('Back')),
                    ],
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
    Future<void>.delayed(const Duration(milliseconds: 400), signer.dispose);

    if (record != null && record.declined && mounted) {
      // Saved so the audit trail shows the patient was asked and said no.
      setState(() {
        _consentRecord = record;
        _consentConfirmed = false;
        _consentAtUtc = null;
      });
      _persist();
      _showMessage('Declined recorded. Type the note instead.', icon: Icons.do_not_disturb_on_outlined);
      return false;
    }
    if (record != null && mounted) {
      setState(() {
        _consentRecord = record;
        _consentConfirmed = true;
        _consentAtUtc = record.atUtc;
      });
      _persist();
      return true;
    }
    return false;
  }

  Future<void> _confirmDeleteEncounter() async {
    final theme = Theme.of(context);
    final error = theme.colorScheme.error;
    final hasContent = _hasNote || _transcriptController.text.trim().isNotEmpty || _isRecording;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: Icon(Icons.delete_outline_rounded, color: error, size: 32),
        title: Text('Discard visit ${widget.visitNumber}?', textAlign: TextAlign.center),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Use this when recording started by accident or captured a conversation that is not about care. '
              'The visit, its recording, note and claim are deleted. Nothing is kept for $_patientName.',
            ),
            if (hasContent) ...[
              const SizedBox(height: 16),
              _discardRow(ctx, Icons.forum_outlined, 'Transcript turns', _encounter.transcript.length),
              _discardRow(ctx, Icons.local_offer_outlined, 'Codes', _encounter.codes.length),
              _discardRow(ctx, Icons.assignment_outlined, 'Orders', _encounter.nextSteps.length),
            ],
            if (_isRecording) ...[
              const SizedBox(height: 12),
              Row(
                children: [
                  Icon(Icons.mic_off_outlined, size: 18, color: error),
                  const SizedBox(width: 8),
                  Expanded(child: Text('The recording in progress will be stopped.', style: TextStyle(color: error))),
                ],
              ),
            ],
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Keep visit')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: error, foregroundColor: theme.colorScheme.onError),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Discard'),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;
    if (_isRecording) {
      await _stopRecording(synthesize: false);
      if (!mounted) return;
    }
    _synthesisGeneration++; // drop any note still being written
    final messenger = ScaffoldMessenger.of(context);
    await _repo.deleteVisit(widget.accountNumber, widget.visitNumber);
    if (!mounted) return;
    Navigator.pop(context);
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text('Visit ${widget.visitNumber} discarded. Nothing was kept.')));
  }

  Widget _discardRow(BuildContext ctx, IconData icon, String label, int count) {
    final theme = Theme.of(ctx);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Icon(icon, size: 20, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(width: 12),
          Expanded(child: Text(label, style: theme.textTheme.bodyMedium)),
          Text('$count', style: theme.textTheme.labelLarge),
        ],
      ),
    );
  }

  String _formattedNote({bool withAddenda = false}) {
    final b = StringBuffer()
      ..writeln('CLINICAL ENCOUNTER NOTE')
      ..writeln('Patient: $_patientName')
      ..writeln('MRN: $_mrn | Age/Sex: $_ageGender | Visit: $_visitType')
      ..writeln('Date of service: ${_encounter.date}')
      ..writeln('Attending: $_attending')
      ..writeln();
    if (_encounter.vitals.isNotEmpty) {
      b.writeln('VITAL SIGNS');
      for (final v in _encounter.vitals) {
        b.writeln('- ${v.label}: ${v.value}${v.isAbnormal ? ' (abnormal)' : ''}');
      }
      b.writeln();
    }
    for (final e in const {
      'subjective': 'SUBJECTIVE',
      'objective': 'OBJECTIVE',
      'assessment': 'ASSESSMENT',
      'plan': 'PLAN',
    }.entries) {
      b
        ..writeln(e.value)
        ..writeln(_soapControllers[e.key]!.text)
        ..writeln();
    }
    if (_encounter.codes.isNotEmpty) {
      b.writeln('DIAGNOSES AND CODES');
      for (final c in _encounter.codes) {
        b.writeln('- ${c.type == 'ICD10' ? 'ICD-10' : 'CPT'} ${c.code}: ${c.description}');
      }
      b.writeln();
    }
    if (_encounter.nextSteps.isNotEmpty) {
      b.writeln('ORDERS');
      for (final a in _encounter.nextSteps) {
        b.writeln('- [${a.urgency}] ${a.title}${a.detailPayload != null ? ' (${a.detailPayload})' : ''}');
      }
      b.writeln();
    }
    if (_isSigned && _encounter.attestationText.isNotEmpty) b.writeln('Attestation (${_encounter.attestationVersion}): ${_encounter.attestationText}');
    b.writeln(_isSigned ? 'Electronically signed by $_attending' : 'DRAFT, not signed');
    if (withAddenda) b.write(_addendaText());
    return b.toString();
  }

  String _addendaText() {
    if (_encounter.addenda.isEmpty) return '';
    final b = StringBuffer()..writeln()..writeln('ADDENDA');
    for (final a in _encounter.addenda) {
      b
        ..writeln('Addendum ${_formatAddendumTime(a.atUtc)} by ${a.signerName} (NPI: ${a.signerNpi})')
        ..writeln(a.text)
        ..writeln('SHA-256 seal: ${a.seal}');
    }
    return b.toString();
  }

  static String _formatAddendumTime(DateTime utc) {
    final t = utc.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${t.year}-${two(t.month)}-${two(t.day)} ${two(t.hour)}:${two(t.minute)}';
  }

  /// Once the claim has gone out, the signed note is a legal record that no
  /// longer changes; corrections are made as addenda.
  bool get _noteLocked => _isSigned && const {VisitStatus.queued, VisitStatus.submitted, VisitStatus.paid, VisitStatus.denied}.contains(_status);

  /// Adds a sealed addendum to the signed note.
  Future<void> _addAddendum() async {
    if (!_isSigned) return;
    final text = await showDialog<String>(context: context, builder: (_) => const _AddendumDialog());
    if (text == null || text.trim().isEmpty || !mounted) return;
    final p = _repo.provider;
    final addendum = NoteAddendum.create(
      text: text,
      atUtc: DateTime.now().toUtc(),
      signerName: p.displayName,
      signerNpi: p.npi,
      noteSeal: _encounter.sha256Seal,
    );
    setState(() => _encounter = _encounter.copyWith(addenda: [..._encounter.addenda, addendum]));
    await _persist();
    _showMessage('Addendum signed and added.', icon: Icons.post_add_rounded);
  }

  void _copyFormattedNote() {
    final seal = _encounter.sha256Seal;
    PhiClipboard.copy(_isSigned && seal.isNotEmpty ? '${_formattedNote()}SHA-256 seal: $seal\n${_addendaText()}' : _formattedNote(withAddenda: true));
    HapticFeedback.lightImpact();
    _showMessage('Note copied. Paste it into the EHR within 60 seconds; then the clipboard clears.', icon: Icons.content_copy_rounded);
  }

  /// Who signed, confirmed, changed and sent what on this visit, newest
  /// first, with a copy of the whole trail for an auditor.
  void _openAuditTrail() {
    final visit = _visitOrNull;
    if (visit == null) return;
    final events = visit.audit.reversed.toList();
    final c = visit.codeConfirmation;
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) {
        final theme = Theme.of(ctx);
        return ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(ctx).height * 0.85),
          child: SafeArea(
            child: ListView(
              key: const Key('audit_trail'),
              shrinkWrap: true,
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
              children: [
                Text('Audit trail', style: theme.textTheme.titleLarge),
                const SizedBox(height: 4),
                Text(
                  c == null
                      ? 'Codes not confirmed yet.'
                      : (_claim != null && !visit.codesConfirmedFor(_claim!))
                          ? 'Codes changed after ${c.by} confirmed them on ${_formatAddendumTime(c.atUtc)}; confirm again before billing.'
                          : 'Codes confirmed by ${c.by} on ${_formatAddendumTime(c.atUtc)}: ${c.codes}.',
                  style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
                const SizedBox(height: 12),
                if (events.isEmpty)
                  const EmptyState(icon: Icons.history_edu_outlined, title: 'Nothing yet', message: 'Signing, code confirmations, code changes and claims are recorded here.')
                else
                  for (final e in events)
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.history_rounded),
                      title: Text(e.action),
                      subtitle: Text([_formatAddendumTime(e.atUtc), e.by, if (e.detail.isNotEmpty) e.detail].join('\n')),
                    ),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  key: const Key('copy_audit'),
                  icon: const Icon(Icons.content_copy_rounded),
                  label: const Text('Copy audit trail'),
                  onPressed: events.isEmpty
                      ? null
                      : () {
                          final text = ['time_utc\tby\taction\tdetail', for (final e in visit.audit) e.toLine()].join('\n');
                          unawaited(PhiClipboard.copy(text));
                          Navigator.pop(ctx);
                          _showMessage('Audit trail copied. It clears from the clipboard in 60 seconds.', icon: Icons.content_copy_rounded);
                        },
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  void _openFhirExportDialog() {
    final fhirBundle = FhirExportService.generateFhirR4Bundle(_encounter);
    final jsonString = const JsonEncoder.withIndent('  ').convert(fhirBundle);
    final entries = (fhirBundle['entry'] as List?)?.length ?? 0;

    showDialog<void>(
      context: context,
      builder: (ctx) {
        final theme = Theme.of(ctx);
        return AlertDialog(
          title: const Text('FHIR R4 export'),
          content: SizedBox(
            width: double.maxFinite,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('Transaction bundle with $entries resources: patient, encounter, vitals, conditions, prescriptions, orders and the signed note.'),
                const SizedBox(height: 12),
                Container(
                  height: 240,
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surfaceContainer,
                    borderRadius: BorderRadius.circular(SolisTheme.radiusMd),
                  ),
                  child: SingleChildScrollView(
                    child: SelectableText(jsonString, style: theme.textTheme.bodySmall?.copyWith(fontFamily: 'monospace', height: 1.4)),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Close')),
            FilledButton.icon(
              icon: const Icon(Icons.content_copy_rounded, size: 18),
              label: const Text('Copy JSON'),
              onPressed: () {
                PhiClipboard.copy(jsonString);
                Navigator.pop(ctx);
                _showMessage('FHIR bundle copied. The clipboard clears in 60 seconds.', icon: Icons.data_object_rounded);
              },
            ),
          ],
        );
      },
    );
  }

  /// Each sentence of a note section with the line of the conversation it
  /// came from, and the sentences that have no source flagged for review.
  void _showEvidence(String sectionTitle, String sectionContent) {
    final turns = _encounter.transcript;
    final links = turns.isEmpty ? const <SentenceSource>[] : NoteSources.link(sectionContent, turns);
    final missing = links.where((l) => l.unsupported).length;
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) {
        final theme = Theme.of(ctx);
        final dark = theme.brightness == Brightness.dark;
        return ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(ctx).height * 0.85),
          child: SafeArea(
            child: ListView(
              key: const Key('sources_sheet'),
              shrinkWrap: true,
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
              children: [
                Text('Sources for $sectionTitle', style: theme.textTheme.titleLarge),
                const SizedBox(height: 4),
                Text(
                  missing == 0
                      ? 'Each sentence with the line of the conversation it came from.'
                      : '$missing ${missing == 1 ? 'sentence has' : 'sentences have'} no source in the conversation. Check or edit ${missing == 1 ? 'it' : 'them'} before signing.',
                  style: theme.textTheme.bodyMedium?.copyWith(color: missing == 0 ? theme.colorScheme.onSurfaceVariant : SolisTheme.onTint(SolisTheme.warning, isDark: dark)),
                ),
                const SizedBox(height: 16),
                if (turns.isEmpty)
                  const EmptyState(icon: Icons.forum_outlined, title: 'No transcript', message: 'Record the visit to link note content to the conversation.')
                else if (links.isEmpty)
                  Text('Nothing documented in this section.', style: theme.textTheme.bodyMedium)
                else
                  for (final l in links.where((l) => l.needsSource))
                    _SentenceSourceTile(link: l, turn: l.turnIndex == null ? null : turns[l.turnIndex!], patientName: _patientName),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  icon: const Icon(Icons.forum_outlined),
                  label: const Text('Open full transcript'),
                  onPressed: () {
                    Navigator.pop(ctx);
                    setState(() => _reviewTab = 1);
                  },
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  /// Sentences across the note with no source in the conversation.
  int get _unsupportedSentences => NoteSources.unsupportedCount(
        [for (final k in const ['subjective', 'objective', 'assessment', 'plan']) _soapControllers[k]!.text],
        _encounter.transcript,
      );

  void _toggleEdit(String key) {
    if (_noteLocked && !(_editing[key] ?? false)) {
      _showMessage('This claim has been sent, so the signed note can no longer change. Add an addendum instead.', icon: Icons.lock_outline_rounded);
      return;
    }
    setState(() {
      final wasEditing = _editing[key] ?? false;
      if (wasEditing) {
        final text = _soapControllers[key]!.text;
        _encounter = switch (key) {
          'subjective' => _encounter.copyWith(subjective: text),
          'objective' => _encounter.copyWith(objective: text),
          'assessment' => _encounter.copyWith(assessment: text),
          _ => _encounter.copyWith(plan: text),
        };
        // Editing a signed note reopens it as a draft; the seal no longer
        // matches the text, so it is removed until the note is signed again.
        if (_isSigned) {
          _isSigned = false;
          _signedAt = null;
          _claimReady = false;
          _encounter = _encounter.copyWith(clearSignature: true);
        }
      }
      _editing[key] = !wasEditing;
    });
    if (_editing[key] == false) unawaited(_record('Edited ${key[0].toUpperCase()}${key.substring(1)}'));
    _persist();
  }

  /// Signs the note: records the time and a SHA-256 seal over the exact
  /// text signed, the signer's NPI and that time.
  void _applySignature() {
    final now = DateTime.now();
    _isSigned = true;
    _signedAt = now;
    // The attestation is stored with its version and is part of the sealed text.
    _encounter = _encounter.copyWith(
      isSigned: true,
      signedAtUtc: now.toUtc(),
      attestationVersion: attestationVersion,
      attestationText: attestationText(_attending),
    );
    _encounter = _encounter.copyWith(
      sha256Seal: NoteSeal.compute(noteText: _formattedNote(), signerNpi: _repo.provider.npi, signedAtUtc: now.toUtc()),
    );
  }

  /// One review sheet for signing (item: sign, ready and send in one step).
  /// It shows the attestation, the claim, every check that is not clean and
  /// the orders to mark as sent, then signs and, when the claim is clean and
  /// a clearinghouse is connected, sends it.
  Future<void> _reviewAndSign() async {
    if (_editing.values.any((e) => e)) {
      _showMessage('Save your edits before signing.', icon: Icons.edit_note_rounded);
      return;
    }
    final claim = _claim;
    final issues = claim == null ? const <ClaimIssue>[] : _issues(claim, signed: true);
    final errors = issues.where((i) => i.severity == IssueSeverity.error).toList();
    final warnings = issues.where((i) => i.severity == IssueSeverity.warning).toList();
    final connected = _claims.isConnected;
    final orders = _encounter.nextSteps.where((a) => !a.isCompleted && a.included).toList();
    final elig = _visit.eligibility;
    final result = await showModalBottomSheet<SignSheetResult>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => SignAndSendSheet(
        attestation: attestationText(_attending),
        claimId: claim == null ? null : ClaimBuilder.claimId(_account, _visit),
        primaryDiagnosis: claim == null || claim.billable.isEmpty ? null : '${claim.billable.first.code}  ${claim.billable.first.description}',
        services: claim == null ? const [] : [for (final l in claim.lines) '${[l.code, ...l.modifiers].join('-')}  ${l.description}'],
        total: claim?.totalCharge,
        errors: errors,
        warnings: warnings,
        eligibility: elig == null ? null : EligibilityService.describe(elig),
        ordersToMark: orders.length,
        connected: connected,
        testMode: _claims.isTest,
        payerName: _account.insurance?.payerName,
        emCode: claim?.emLine?.code,
      ),
    );
    if (result == null || !mounted) return;
    // The note is signed either way; only billing the claim waits for Pro.
    var billNow = errors.isEmpty && claim != null;
    if (billNow && !await _proForClaim()) billNow = false;
    if (!mounted) return;
    HapticFeedback.mediumImpact();
    setState(() {
      _applySignature();
      if (result.markOrders) {
        for (final a in orders) {
          a.isCompleted = true;
        }
      }
      if (billNow && !connected) _claimReady = true;
    });
    await _persist();
    await _record('Signed note', detail: _encounter.sha256Seal.isEmpty ? '' : 'seal ${_encounter.sha256Seal.substring(0, 16)}');
    if (result.codesConfirmed && claim != null) await _record('Confirmed E/M level and codes', detail: claim.codeSummary, confirmCodes: true);
    if (!mounted) return;
    if (errors.isNotEmpty) {
      setState(() => _reviewTab = 3);
      _showMessage('Note signed. Fix ${errors.length} claim ${errors.length == 1 ? 'issue' : 'issues'} before billing.', icon: Icons.verified_outlined);
      WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToChecks());
      return;
    }
    if (connected && billNow) {
      await _sendNow();
      return;
    }
    _showMessage(
      claim == null ? 'Note signed.' : (billNow ? 'Note signed. Claim ready to bill.' : 'Note signed. Start SOLIS Pro to bill the claim.'),
      icon: Icons.verified_outlined,
    );
  }

  void _scrollToChecks() {
    final ctx = _checksKey.currentContext;
    if (ctx != null) Scrollable.ensureVisible(ctx, duration: const Duration(milliseconds: 300), alignment: 0.05);
  }

  /// Marks the ticked orders as sent. There is no ordering integration, so
  /// this records that the clinician entered them elsewhere; Undo reverts.
  void _markOrdersSent() {
    final picked = _encounter.nextSteps.where((a) => !a.isCompleted && a.included).toList();
    if (picked.isEmpty) return;
    HapticFeedback.mediumImpact();
    setState(() {
      for (final a in picked) {
        a.isCompleted = true;
      }
    });
    _persist();
    _showMessage(
      '${picked.length} ${picked.length == 1 ? 'order' : 'orders'} marked as sent. Enter them in your EHR or ordering system.',
      icon: Icons.task_alt_rounded,
      action: SnackBarAction(
        label: 'Undo',
        onPressed: () {
          if (!mounted) return;
          setState(() {
            for (final a in picked) {
              a.isCompleted = false;
            }
          });
          _persist();
        },
      ),
    );
  }

  void _openTypeSheet() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) {
        final theme = Theme.of(ctx);
        return Padding(
          padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(ctx).bottom),
          child: SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text('Type or paste the conversation', style: theme.textTheme.titleLarge),
                  const SizedBox(height: 4),
                  Text(
                    'Start lines with "Doctor:" or "Patient:" to separate speakers.',
                    style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: _transcriptController,
                    autofocus: true,
                    minLines: 6,
                    maxLines: 12,
                    textCapitalization: TextCapitalization.sentences,
                    decoration: const InputDecoration(hintText: 'Doctor: What brings you in today?\nPatient: ...'),
                  ),
                  if (_account.sampleConversationKey != null) ...[
                    const SizedBox(height: 8),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton.icon(
                        icon: const Icon(Icons.science_outlined),
                        label: const Text('Insert sample conversation'),
                        onPressed: () => _transcriptController.text = sampleConversations[_account.sampleConversationKey] ?? '',
                      ),
                    ),
                  ],
                  const SizedBox(height: 16),
                  FilledButton.icon(
                    icon: const Icon(Icons.auto_awesome_outlined),
                    label: const Text('Create note'),
                    onPressed: () {
                      if (_transcriptController.text.trim().isEmpty) return;
                      Navigator.pop(ctx);
                      setState(() => _reviewTab = 0);
                      _synthesizeEncounter();
                    },
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  void _openSessionDetails() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheetState) {
          final theme = Theme.of(ctx);
          void update(VoidCallback fn) {
            setState(fn);
            setSheetState(() {});
          }

          final lat = (_currentGps['latitude'] as num?)?.toDouble();
          final lng = (_currentGps['longitude'] as num?)?.toDouble();
          final alt = (_currentGps['altitude'] as num?)?.toDouble();
          final acc = (_currentGps['accuracy'] as num?)?.toDouble();

          Widget heading(String text) => Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
                child: Text(text, style: theme.textTheme.labelLarge?.copyWith(color: theme.colorScheme.primary)),
              );

          return ConstrainedBox(
            constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(ctx).height * 0.85),
            child: SafeArea(
              child: ListView(
                shrinkWrap: true,
                padding: const EdgeInsets.only(bottom: 16),
                children: [
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Text('Session details', style: theme.textTheme.titleLarge),
                  ),
                  heading('Note engine'),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    child: SegmentedButton<bool>(
                      segments: const [
                        ButtonSegment(value: true, icon: Icon(Icons.smartphone_outlined), label: Text('On device')),
                        ButtonSegment(value: false, icon: Icon(Icons.cloud_outlined), label: Text('Cloud')),
                      ],
                      selected: {_isOffline},
                      onSelectionChanged: (s) => update(() => _isOffline = s.first),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Text(
                      _isOffline
                          ? 'Notes are written on this phone. Nothing leaves the device until backup.'
                          : 'Notes are written by the cloud model. Falls back to the device when offline.',
                      style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                    ),
                  ),
                  heading('Microphone'),
                  SwitchListTile(
                    key: const Key('noise_suppression'),
                    secondary: const Icon(Icons.noise_control_off_outlined),
                    title: const Text('Noise suppression'),
                    subtitle: Text(
                      "Android's noise suppressor on the microphone, for the voice-separation engines. "
                      '${_isRecording ? 'Applies from the next recording.' : 'Applies when recording starts.'}',
                    ),
                    value: _noiseSuppression,
                    onChanged: (v) => update(() => _noiseSuppression = v),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    child: SegmentedButton<SpeechLanguage>(
                      key: const Key('speech_language'),
                      segments: [
                        for (final l in SpeechLanguage.values) ButtonSegment(value: l, icon: const Icon(Icons.translate_outlined), label: Text(l.label)),
                      ],
                      selected: {_language},
                      onSelectionChanged: (s) => update(() => _language = s.first),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Text(
                      _language == SpeechLanguage.english
                          ? 'Recognizes US English.'
                          : 'Deepgram listens for Spanish and English together; basic recognition uses US Spanish. '
                              'The on-device engine is English only and is not used.',
                      style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                    ),
                  ),
                  heading('Audit trail'),
                  ListTile(
                    leading: Icon(_consentDeclined
                        ? Icons.do_not_disturb_on_outlined
                        : _consentConfirmed
                            ? Icons.verified_user_outlined
                            : Icons.gpp_maybe_outlined),
                    title: const Text('Recording consent'),
                    subtitle: Text(_consentSummary),
                  ),
                  ListTile(
                    leading: Icon(_hasFix ? Icons.location_on_outlined : Icons.location_off_outlined),
                    title: const Text('Location'),
                    subtitle: Text(
                      !_hasFix || lat == null || lng == null
                          ? '$_locationLabel. ${_currentGps['reason'] == 'permission_denied' ? 'Allow location in Android settings to tag visits.' : 'The visit is saved without a location rather than a guessed one.'}'
                          : [
                              if (_currentGps['address'] != null) '${_currentGps['address']}',
                              '${lat.toStringAsFixed(5)}, ${lng.toStringAsFixed(5)}'
                                  '${acc != null ? ' (+/- ${acc.toStringAsFixed(0)} m)' : ''}'
                                  '${alt != null ? ', altitude ${alt.toStringAsFixed(0)} m' : ''}',
                            ].join('\n'),
                    ),
                    trailing: IconButton(
                      tooltip: 'Refresh location',
                      icon: const Icon(Icons.my_location_rounded),
                      onPressed: () async {
                        await _refreshLocation();
                        setSheetState(() {});
                      },
                    ),
                  ),
                  if (_hasFix && lat != null && lng != null)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: TextButton.icon(
                          key: const Key('save_place'),
                          icon: const Icon(Icons.add_location_alt_outlined),
                          label: Text(matchSavedPlace(_repo.provider.savedPlaces, _currentGps) == null ? 'Save this place' : 'At ${matchSavedPlace(_repo.provider.savedPlaces, _currentGps)!.name}'),
                          onPressed: matchSavedPlace(_repo.provider.savedPlaces, _currentGps) != null
                              ? null
                              : () async {
                                  await _savePlace(lat, lng);
                                  setSheetState(() {});
                                },
                        ),
                      ),
                    ),
                  ListTile(
                    leading: const Icon(Icons.schedule_outlined),
                    title: const Text('Date of service'),
                    subtitle: Text('${formatDos(_visit.dateOfService)}, ${placeOfService(_visit.placeOfService).label}\n${DateTime.now().toUtc().toIso8601String()} UTC'),
                  ),
                  ListTile(
                    leading: Icon(_isFlagSecureActive ? Icons.screen_lock_portrait_outlined : Icons.screenshot_outlined),
                    title: const Text('Screen protection'),
                    subtitle: Text(
                      _isFlagSecureActive
                          ? 'Screenshots, screen recording and app previews are blocked'
                          : 'Screenshots allowed. Turn on blocking in the provider profile.',
                    ),
                  ),
                  ListTile(
                    leading: const Icon(Icons.lock_clock_outlined),
                    title: const Text('Background capture'),
                    subtitle: Text(
                      _isBackgroundWakeLockActive
                          ? 'On. Recording continues with the screen off.'
                          : 'Turns on automatically while recording',
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  bool get _consentDeclined => _consentRecord?.declined ?? false;

  String get _consentSummary {
    final r = _consentRecord;
    if (_consentConfirmed && _consentAtUtc != null) {
      final how = r?.method == 'signature' ? 'Signed by ${r?.signedBy ?? 'the patient'}' : 'Verbal consent';
      return '$how at ${_formatClock(_consentAtUtc!.toLocal())}';
    }
    if (r != null && r.declined) return 'Patient declined recording at ${_formatClock(r.atUtc.toLocal())}';
    return 'Asked before the first recording';
  }

  /// Saves the current location as a place with this visit's place of
  /// service, so later visits there pick it automatically.
  Future<void> _savePlace(double lat, double lng) async {
    final name = TextEditingController();
    var pos = _visit.placeOfService;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialog) => AlertDialog(
          title: const Text('Save this place'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                key: const Key('place_name'),
                controller: name,
                autofocus: true,
                textCapitalization: TextCapitalization.words,
                decoration: const InputDecoration(labelText: 'Name', hintText: 'Sunrise Skilled Nursing'),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                initialValue: pos,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Place of service'),
                items: [for (final p in placesOfService) DropdownMenuItem(value: p.code, child: Text(p.label, overflow: TextOverflow.ellipsis))],
                onChanged: (v) => setDialog(() => pos = v ?? pos),
              ),
              const SizedBox(height: 8),
              Text(
                'Visits started within 150 m of here use this place of service. You can still change it on each visit.',
                style: Theme.of(ctx).textTheme.bodySmall?.copyWith(color: Theme.of(ctx).colorScheme.onSurfaceVariant),
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(ctx, name.text.trim().isNotEmpty), child: const Text('Save')),
          ],
        ),
      ),
    );
    final label = name.text.trim();
    Future<void>.delayed(const Duration(milliseconds: 400), name.dispose);
    if (ok != true || !mounted) return;
    final p = _repo.provider;
    await _repo.saveProvider(p.copyWith(savedPlaces: [
      ...p.savedPlaces,
      SavedPlace(
        id: 'place-${DateTime.now().millisecondsSinceEpoch}',
        name: label,
        placeOfService: pos,
        latitude: lat,
        longitude: lng,
        address: _currentGps['address']?.toString(),
      ),
    ]));
    if (mounted) _showMessage('Saved $label. Visits there use ${placeOfService(pos).label}.', icon: Icons.place_outlined);
  }

  static String _formatClock(DateTime t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

  static String _formatElapsed(int seconds) {
    final m = (seconds ~/ 60).toString().padLeft(2, '0');
    final s = (seconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  static bool _isSmallTalk(String text) {
    final lower = text.toLowerCase();
    const markers = [
      'basketball', 'warriors', 'overtime', 'screaming', 'good morning', 'how are you feeling today',
      'weekend', 'weather', 'holiday', 'embarrassing story', 'pickup soccer',
    ];
    return markers.any(lower.contains);
  }

  // ---------------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final phase = _phase;
    return PopScope(
      canPop: !_isRecording,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _isRecording) {
          _showMessage('Finish or discard the recording before leaving.', icon: Icons.mic_rounded);
        }
      },
      child: Scaffold(
        appBar: _buildAppBar(context),
        body: SafeArea(
          top: false,
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 200),
            child: switch (phase) {
              _Phase.ready => _buildReady(context),
              _Phase.recording => _buildRecording(context),
              _Phase.generating => _buildGenerating(context),
              _Phase.review => _buildReview(context),
            },
          ),
        ),
        bottomNavigationBar: phase == _Phase.review ? _buildReviewBar(context) : null,
      ),
    );
  }

  PreferredSizeWidget _buildAppBar(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final hasNote = _hasNote;
    final compact = MediaQuery.sizeOf(context).width < 400;

    return AppBar(
      leading: IconButton(
        icon: const Icon(Icons.arrow_back_rounded),
        tooltip: 'Back to patient',
        onPressed: _isRecording ? null : () => Navigator.maybePop(context),
      ),
      titleSpacing: 0,
      title: Semantics(
        label: 'Patient $_patientName, $_ageGender. $_visitType',
        excludeSemantics: true,
        child: InkWell(
          onTap: null,
          borderRadius: BorderRadius.circular(SolisTheme.radiusSm),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            child: Row(
              children: [
                Flexible(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(_patientName, maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.titleMedium),
                      Text(
                        '$_ageGender  |  Visit ${widget.visitNumber}  |  ${formatDos(_visit.dateOfService)}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
      actions: [
        if (hasNote && !_isRecording && !compact)
          IconButton(icon: const Icon(Icons.content_copy_rounded), tooltip: 'Copy note', onPressed: _copyFormattedNote),
        IconButton(icon: const Icon(Icons.delete_outline_rounded), tooltip: 'Discard visit', onPressed: _confirmDeleteEncounter),
        PopupMenuButton<String>(
          tooltip: 'More',
          onSelected: (v) {
            switch (v) {
              case 'copy':
                _copyFormattedNote();
              case 'session':
                _openSessionDetails();
              case 'fhir':
                _openFhirExportDialog();
              case 'audit':
                _openAuditTrail();
              case 'theme':
                widget.onThemeToggle?.call(!widget.isDark);
            }
          },
          itemBuilder: (_) => [
            if (hasNote && !_isRecording && compact) _menuItem('copy', Icons.content_copy_rounded, 'Copy note'),
            _menuItem('session', Icons.tune_rounded, 'Session details'),
            if (hasNote) _menuItem('fhir', Icons.data_object_rounded, 'Export FHIR R4'),
            _menuItem('audit', Icons.history_edu_outlined, 'Audit trail'),
            if (widget.onThemeToggle != null)
              _menuItem('theme', widget.isDark ? Icons.light_mode_outlined : Icons.dark_mode_outlined, widget.isDark ? 'Light theme' : 'Dark theme'),
          ],
        ),
      ],
      bottom: PreferredSize(preferredSize: const Size.fromHeight(36), child: _buildSessionStrip(context)),
    );
  }

  PopupMenuItem<String> _menuItem(String value, IconData icon, String label) => PopupMenuItem(
        value: value,
        child: Row(children: [Icon(icon, size: 20), const SizedBox(width: 12), Text(label)]),
      );

  /// One quiet line of session context. Tapping opens the full details. This
  /// replaces a row of always-on badges, which trains people to ignore status.
  Widget _buildSessionStrip(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final style = theme.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant);

    Widget item(IconData icon, String text, {Color? color}) => Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 16, color: color ?? cs.onSurfaceVariant),
            const SizedBox(width: 4),
            Text(text, style: color != null ? style?.copyWith(color: color) : style),
          ],
        );

    return InkWell(
      onTap: _openSessionDetails,
      child: Container(
        height: 36,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        decoration: BoxDecoration(border: Border(bottom: BorderSide(color: cs.outlineVariant))),
        child: Row(
          children: [
            Expanded(
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                physics: const NeverScrollableScrollPhysics(),
                child: Row(
                  children: [
                    item(_isOffline ? Icons.smartphone_outlined : Icons.cloud_outlined, _isOffline ? 'On device' : 'Cloud'),
                    const SizedBox(width: 16),
                    item(
                      _consentDeclined
                          ? Icons.do_not_disturb_on_outlined
                          : _consentConfirmed
                              ? Icons.verified_user_outlined
                              : Icons.gpp_maybe_outlined,
                      _consentDeclined ? 'Declined' : (_consentConfirmed ? 'Consent' : 'No consent yet'),
                    ),
                    const SizedBox(width: 16),
                    item(_hasFix || !_gpsResolved ? Icons.location_on_outlined : Icons.location_off_outlined, _locationLabel),
                  ],
                ),
              ),
            ),
            Icon(Icons.chevron_right_rounded, size: 20, color: cs.onSurfaceVariant),
          ],
        ),
      ),
    );
  }

  // --- Ready ---------------------------------------------------------------

  Widget _buildReady(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final declined = _consentDeclined;
    final visit = _visit;
    final pos = placeOfService(visit.placeOfService);
    final configured = _eligibility.isConfigured;
    final elig = visit.eligibility;
    final eligState = EligibilityService.stateOf(elig);
    final dark = theme.brightness == Brightness.dark;
    final (eligIcon, eligColor) = switch (eligState) {
      EligibilityState.active => (Icons.verified_outlined, SolisTheme.onTint(SolisTheme.success, isDark: dark)),
      EligibilityState.inactive => (Icons.block_rounded, SolisTheme.onTint(SolisTheme.danger, isDark: dark)),
      EligibilityState.failed => (Icons.warning_amber_rounded, SolisTheme.onTint(SolisTheme.warning, isDark: dark)),
      EligibilityState.notChecked => (Icons.help_outline_rounded, cs.onSurfaceVariant),
    };
    final sinceLast = _sinceLastVisit(context);

    return CustomScrollView(
      key: const ValueKey('ready'),
      slivers: [
        SliverFillRemaining(
          hasScrollBody: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 16, 24, 16),
            child: Column(
              children: [
                Wrap(
                  alignment: WrapAlignment.center,
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    ActionChip(
                      key: const Key('ready_pos'),
                      avatar: const Icon(Icons.place_outlined, size: 18),
                      label: Text(pos.label),
                      tooltip: 'Change place of service',
                      onPressed: () async {
                        final picked = await pickPlaceOfService(context, visit.placeOfService);
                        if (picked != null && picked != visit.placeOfService) await _changePlaceOfService(picked);
                      },
                    ),
                  ],
                ),
                if (_account.insurance != null) ...[
                  const SizedBox(height: 8),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(eligIcon, size: 18, color: eligColor),
                      const SizedBox(width: 8),
                      Flexible(
                        child: Text(
                          EligibilityService.describe(elig, configured: configured),
                          key: const Key('ready_eligibility'),
                          style: theme.textTheme.bodyMedium?.copyWith(color: eligColor),
                        ),
                      ),
                    ],
                  ),
                ],
                const Spacer(),
                Text(declined ? 'Recording declined' : 'Ready to record', style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w600)),
                const SizedBox(height: 8),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 360),
                  child: Text(
                    declined
                        ? 'The patient said no to recording. Type the conversation or the note instead.'
                        : 'Put the phone between you and the patient, then talk as you normally would. '
                            'SOLIS writes the note when you finish.',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodyLarge?.copyWith(color: cs.onSurfaceVariant),
                  ),
                ),
                const SizedBox(height: 32),
                if (declined)
                  SizedBox(
                    height: 56,
                    child: FilledButton.icon(
                      key: const Key('ready_type_primary'),
                      icon: const Icon(Icons.keyboard_outlined),
                      label: const Text('Type instead'),
                      onPressed: _openTypeSheet,
                    ),
                  )
                else ...[
                  RecordButton(onPressed: _onRecordPressed),
                  const SizedBox(height: 16),
                  Text('Tap to start', style: theme.textTheme.labelLarge?.copyWith(color: cs.onSurfaceVariant)),
                ],
                const SizedBox(height: 24),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      declined
                          ? Icons.do_not_disturb_on_outlined
                          : _consentConfirmed
                              ? Icons.verified_user_outlined
                              : Icons.record_voice_over_outlined,
                      size: 18,
                      color: cs.onSurfaceVariant,
                    ),
                    const SizedBox(width: 8),
                    Flexible(
                      child: Text(
                        declined || _consentConfirmed ? _consentSummary : 'You will confirm patient consent first',
                        style: theme.textTheme.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
                      ),
                    ),
                  ],
                ),
                if (sinceLast != null) ...[
                  const SizedBox(height: 16),
                  sinceLast,
                ],
                const Spacer(flex: 2),
                Wrap(
                  alignment: WrapAlignment.center,
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    if (declined)
                      OutlinedButton.icon(
                        key: const Key('ready_ask_again'),
                        icon: const Icon(Icons.record_voice_over_outlined),
                        label: const Text('Ask again'),
                        onPressed: _onRecordPressed,
                      )
                    else
                      OutlinedButton.icon(
                        icon: const Icon(Icons.keyboard_outlined),
                        label: const Text('Type instead'),
                        onPressed: _openTypeSheet,
                      ),
                    if (_account.sampleConversationKey != null && _repo.demoMode)
                      OutlinedButton.icon(
                        icon: const Icon(Icons.science_outlined),
                        label: const Text('Sample conversation'),
                        onPressed: () {
                          _transcriptController.text = sampleConversations[_account.sampleConversationKey] ?? '';
                          setState(() => _reviewTab = 0);
                          _synthesizeEncounter();
                        },
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  /// "Since last visit" for a returning patient: date and place, the codes
  /// billed, Z79 medications and follow-up lines of the plan. Only what was
  /// stored at that visit; nothing is inferred.
  Widget? _sinceLastVisit(BuildContext context) {
    Visit? last;
    for (final v in _account.visits) {
      if (v.number < widget.visitNumber && (v.claim != null || v.encounter != null) && (last == null || v.number > last.number)) last = v;
    }
    if (last == null) return null;
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final dx = last.claim?.billable ?? const <ClaimDiagnosis>[];
    final meds = dx.where((d) => d.code.toUpperCase().startsWith('Z79')).toList();
    final other = dx.where((d) => !d.code.toUpperCase().startsWith('Z79')).take(4).toList();
    final plan = (last.encounter?['plan'] as String? ?? '')
        .split('\n')
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty && RegExp(r'follow[ -]?up|recheck|pending|return', caseSensitive: false).hasMatch(l))
        .take(3)
        .toList();
    Widget line(String text) => Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text(text, style: theme.textTheme.bodyMedium, maxLines: 2, overflow: TextOverflow.ellipsis),
        );
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 480),
      child: SectionCard(
        key: const Key('since_last_visit'),
        title: 'Since last visit',
        icon: Icons.history_rounded,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Visit ${last.number}, ${formatDos(last.dateOfService)}, ${placeOfService(last.placeOfService).label}',
                style: theme.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
            for (final d in other) line('${d.code}  ${d.description}'),
            for (final d in meds) line('${d.code}  ${d.description}'),
            for (final p in plan) line(p),
            if (other.isEmpty && meds.isEmpty && plan.isEmpty) line('No diagnoses were billed at that visit.'),
          ],
        ),
      ),
    );
  }

  // --- Recording -----------------------------------------------------------

  Widget _buildRecording(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final dark = widget.isDark;
    final stateColor = _isPaused ? SolisTheme.warning : SolisTheme.danger;
    final stateFg = SolisTheme.onTint(stateColor, isDark: dark);
    final transcript = _transcriptController.text;

    return Padding(
      key: const ValueKey('recording'),
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Center(
            child: Semantics(
              liveRegion: true,
              child: StatusTag(
                label: _isPaused ? 'Paused' : 'Recording',
                color: stateColor,
                icon: _isPaused ? Icons.pause_rounded : Icons.mic_rounded,
              ),
            ),
          ),
          const SizedBox(height: 12),
          Text(
            _formatElapsed(_recordSeconds),
            textAlign: TextAlign.center,
            style: theme.textTheme.displayMedium?.copyWith(
              fontWeight: FontWeight.w500,
              color: cs.onSurface,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
          const SizedBox(height: 8),
          Center(child: LevelMeter(level: _micLevel, active: !_isPaused, color: stateFg)),
          if (_noSound && !_isPaused) ...[
            const SizedBox(height: 8),
            Center(
              child: Semantics(
                liveRegion: true,
                child: const StatusTag(label: 'No sound', color: SolisTheme.warning, icon: Icons.mic_off_outlined),
              ),
            ),
            const SizedBox(height: 4),
            Text(
              'SOLIS hears nothing. Check the microphone.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(color: SolisTheme.onTint(SolisTheme.warning, isDark: dark)),
            ),
          ],
          const SizedBox(height: 16),
          Expanded(
            child: Card(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text('Live transcript', style: theme.textTheme.labelLarge?.copyWith(color: cs.onSurfaceVariant)),
                    const SizedBox(height: 8),
                    Expanded(
                      child: transcript.trim().isEmpty
                          ? Center(
                              child: Text(
                                _isPaused ? 'Paused. Nothing is being captured.' : 'Listening. ${_engineKind.label}.',
                                textAlign: TextAlign.center,
                                style: theme.textTheme.bodyLarge?.copyWith(color: cs.onSurfaceVariant),
                              ),
                            )
                          : SingleChildScrollView(
                              controller: _liveScroll,
                              child: Text(transcript, style: theme.textTheme.bodyLarge),
                            ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              SizedBox(
                width: 64,
                height: 56,
                child: OutlinedButton(
                  style: OutlinedButton.styleFrom(padding: EdgeInsets.zero),
                  onPressed: _togglePause,
                  child: Icon(_isPaused ? Icons.play_arrow_rounded : Icons.pause_rounded, size: 28, semanticLabel: _isPaused ? 'Resume' : 'Pause'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: SizedBox(
                  height: 56,
                  child: FilledButton.icon(
                    onPressed: () => _stopRecording(synthesize: true),
                    icon: const Icon(Icons.check_rounded),
                    label: const Text('Finish and write note'),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          TextButton.icon(
            style: TextButton.styleFrom(foregroundColor: cs.error),
            onPressed: _confirmDeleteEncounter,
            icon: const Icon(Icons.delete_outline_rounded),
            label: const Text('Discard recording'),
          ),
        ],
      ),
    );
  }

  // --- Generating ----------------------------------------------------------

  Widget _buildGenerating(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      key: const ValueKey('generating'),
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(width: 48, height: 48, child: CircularProgressIndicator(strokeWidth: 3)),
            const SizedBox(height: 24),
            Text('Writing the note', style: theme.textTheme.titleLarge),
            const SizedBox(height: 8),
            Text(
              _isOffline || !SolisBackend.instance.isConfigured ? 'Using the on-device engine' : 'Using the cloud model',
              style: theme.textTheme.bodyLarge?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
            if (_pendingLocal != null) ...[
              const SizedBox(height: 24),
              OutlinedButton.icon(
                key: const Key('use_on_device_now'),
                onPressed: _useOnDeviceNow,
                icon: const Icon(Icons.smartphone_outlined),
                label: const Text('Stop waiting, use the on-device note'),
              ),
            ],
          ],
        ),
      ),
    );
  }

  // --- Review --------------------------------------------------------------

  Widget _buildReview(BuildContext context) {
    return Column(
      key: const ValueKey('review'),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: SizedBox(
            width: double.infinity,
            child: SegmentedButton<int>(
              showSelectedIcon: false,
              segments: const [
                ButtonSegment(value: 0, label: Text('Note')),
                ButtonSegment(value: 1, label: Text('Talk')),
                ButtonSegment(value: 2, label: Text('Orders')),
                ButtonSegment(value: 3, label: Text('Claim')),
              ],
              selected: {_reviewTab},
              onSelectionChanged: (s) => setState(() => _reviewTab = s.first),
            ),
          ),
        ),
        Expanded(
          child: switch (_reviewTab) {
            1 => _buildTranscriptTab(context),
            2 => _buildOrdersTab(context),
            3 => _claim == null
                ? const EmptyState(icon: Icons.receipt_long_outlined, title: 'No claim yet', message: 'The claim is built when the note is written.')
                : ClaimTab(
                    claim: _claim!,
                    account: _account,
                    visit: _visit,
                    provider: _repo.provider,
                    noteSigned: _isSigned,
                    claimReady: _claimReady,
                    demoMode: _repo.demoMode,
                    onClaimChanged: _onClaimChanged,
                    onPlaceOfServiceChanged: _changePlaceOfService,
                    onTransportChanged: _onTransportChanged,
                    onReferralChanged: _onReferralChanged,
                    onFacilityChanged: _onFacilityChanged,
                    onFix: _onFix,
                    checksKey: _checksKey,
                    eligibilityConfigured: _eligibility.isConfigured,
                    header: _submissionHeader(context),
                  ),
            _ => _buildNoteTab(context),
          },
        ),
      ],
    );
  }

  Widget _buildReviewBar(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final onOrders = _reviewTab == 2;
    final pending = _pendingOrders;

    final onClaim = _reviewTab == 3;
    final claim = _claim;
    final claimErrors = claim == null ? 1 : _issues(claim).where((i) => i.severity == IssueSeverity.error).length;
    // Errors other than the missing signature: signing does not fix these.
    final blockingErrors = claim == null ? 0 : _issues(claim, signed: true).where((i) => i.severity == IssueSeverity.error).length;
    final connected = _claims.isConnected;

    final Widget primary;
    if (onClaim) {
      primary = _submitting
          ? const FilledButton(onPressed: null, child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)))
          : _afterReady == VisitStatus.queued
              ? FilledButton.icon(onPressed: _sendNow, icon: const Icon(Icons.schedule_send_outlined), label: const Text('Retry now'))
              : _afterReady == VisitStatus.submitted
                  ? FilledButton.icon(onPressed: _checkClaimStatus, icon: const Icon(Icons.fact_check_outlined), label: const Text('Check claim status'))
                  : !_isSigned && blockingErrors == 0
                      ? FilledButton.icon(onPressed: _reviewAndSign, icon: const Icon(Icons.draw_outlined), label: const Text('Review and sign'))
                      : claimErrors > 0
                          ? FilledButton.tonalIcon(
                              key: const Key('show_issues'),
                              onPressed: _scrollToChecks,
                              icon: const Icon(Icons.arrow_downward_rounded),
                              label: Text('Show $claimErrors ${claimErrors == 1 ? 'issue' : 'issues'}'),
                            )
                          : (_afterReady == VisitStatus.paid || _afterReady == VisitStatus.denied)
                              ? FilledButton.icon(onPressed: _copyClaim, icon: const Icon(Icons.task_alt_rounded), label: Text(visitStatusLabel(_afterReady!)))
                              : connected
                                  ? FilledButton.icon(
                                      onPressed: _submitClaim,
                                      icon: const Icon(Icons.outbox_outlined),
                                      label: Text(_afterReady == VisitStatus.rejected ? 'Fix and resend' : 'Send claim'),
                                    )
                                  : _claimReady
                                      ? FilledButton.icon(onPressed: _copyClaim, icon: const Icon(Icons.task_alt_rounded), label: const Text('Ready. Copy claim'))
                                      : FilledButton.icon(onPressed: _markClaimReady, icon: const Icon(Icons.task_alt_rounded), label: const Text('Mark ready to bill'));
    } else if (onOrders) {
      final picked = _encounter.nextSteps.where((a) => !a.isCompleted && a.included).length;
      primary = FilledButton.icon(
        key: const Key('mark_orders_sent'),
        onPressed: picked == 0 ? null : _markOrdersSent,
        icon: const Icon(Icons.task_alt_rounded),
        label: Text(pending == 0
            ? 'All orders marked sent'
            : picked == 0
                ? 'Tick orders to mark'
                : 'Mark $picked ${picked == 1 ? 'order' : 'orders'} as sent'),
      );
    } else if (_isSigned) {
      primary = FilledButton.icon(
        style: FilledButton.styleFrom(
          backgroundColor: SolisTheme.tint(SolisTheme.success, isDark: widget.isDark),
          foregroundColor: SolisTheme.onTint(SolisTheme.success, isDark: widget.isDark),
        ),
        onPressed: _copyFormattedNote,
        icon: const Icon(Icons.verified_outlined),
        label: const Text('Signed. Copy note'),
      );
    } else {
      primary = FilledButton.icon(
        key: const Key('review_and_sign'),
        onPressed: _reviewAndSign,
        icon: const Icon(Icons.draw_outlined),
        label: Text(blockingErrors == 0 ? 'Review and sign' : 'Sign note'),
      );
    }

    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context).scaffoldBackgroundColor,
        border: Border(top: BorderSide(color: cs.outlineVariant)),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
          child: Row(
            children: [
              if (onClaim)
                Tooltip(
                  message: 'Copy the claim as JSON for billing software',
                  child: SizedBox(
                    height: 48,
                    child: PopupMenuButton<String>(
                      tooltip: 'Export the claim',
                      onSelected: (v) {
                        switch (v) {
                          case 'x12':
                            _copyX12();
                          case 'corrected':
                            _replaceClaim(ClaimFrequency.replacement);
                          case 'void':
                            _replaceClaim(ClaimFrequency.voided);
                          default:
                            _copyClaim();
                        }
                      },
                      itemBuilder: (_) => [
                        const PopupMenuItem(value: 'x12', child: Text('Copy 837P file')),
                        const PopupMenuItem(value: 'json', child: Text('Copy JSON')),
                        if (_claims.isConnected && ClaimSubmissionService.canReplace(_visit)) ...[
                          const PopupMenuDivider(),
                          const PopupMenuItem(value: 'corrected', child: Text('Send corrected claim')),
                          const PopupMenuItem(value: 'void', child: Text('Void claim')),
                        ],
                      ],
                      child: IgnorePointer(
                        child: OutlinedButton.icon(onPressed: () {}, icon: const Icon(Icons.ios_share_rounded), label: const Text('Export')),
                      ),
                    ),
                  ),
                )
              else
                Tooltip(
                  message: 'Record more of this visit',
                  child: SizedBox(
                    height: 48,
                    child: OutlinedButton.icon(
                      onPressed: _isSigned ? null : _onRecordPressed,
                      icon: const Icon(Icons.mic_none_rounded),
                      label: const Text('Add'),
                    ),
                  ),
                ),
              const SizedBox(width: 12),
              Expanded(child: SizedBox(height: 48, child: primary)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildNoteTab(BuildContext context) {
    final theme = Theme.of(context);
    const sections = [
      ('subjective', 'Subjective'),
      ('objective', 'Objective'),
      ('assessment', 'Assessment'),
      ('plan', 'Plan'),
    ];
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      children: [
        if (_interrupted != null && !_isRecording) ...[
          _buildInterruptedCard(context, _interrupted!),
          const SizedBox(height: 12),
        ],
        if (_isSigned)
          NoteBanner(
            icon: Icons.verified_outlined,
            title: 'Signed${_signedAt != null ? ' at ${_formatClock(_signedAt!)}' : ''}',
            message: [
              _noteLocked ? 'The claim has been sent, so corrections are added as addenda.' : 'Editing any section reopens the note as a draft.',
              if (_encounter.sha256Seal.isNotEmpty) 'SHA-256 seal ${_encounter.sha256Seal.substring(0, 16)}',
            ].join('\n'),
            color: SolisTheme.success,
          )
        else
          Builder(builder: (context) {
            final missing = _unsupportedSentences;
            return NoteBanner(
              key: const Key('draft_banner'),
              icon: missing == 0 ? Icons.rate_review_outlined : Icons.report_outlined,
              title: missing == 0 ? 'Draft for your review' : 'Draft: $missing ${missing == 1 ? 'sentence' : 'sentences'} without a source',
              message: missing == 0
                  ? 'Tap any section to see the line of the conversation behind each sentence.'
                  : 'Highlighted sentences were not found in the conversation. Tap a section to check them, then edit or keep them.',
              color: missing == 0 ? SolisTheme.info : SolisTheme.warning,
            );
          }),
        const SizedBox(height: 12),
        if (_encounter.vitals.isNotEmpty) ...[
          VitalsPanel(vitals: _encounter.vitals),
          const SizedBox(height: 12),
        ],
        for (final (key, title) in sections) ...[
          _buildSoapSection(context, key, title),
          const SizedBox(height: 12),
        ],
        if (_isSigned) ...[
          _buildAddenda(context),
          const SizedBox(height: 12),
        ],
        if (_claim != null) _buildCodingSummary(context),
        if (_encounter.cdiRecommendations.isNotEmpty) ...[
          const SizedBox(height: 12),
          SectionCard(
            title: 'Documentation suggestions',
            icon: Icons.lightbulb_outline_rounded,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final r in _encounter.cdiRecommendations)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: Icon(Icons.subdirectory_arrow_right_rounded, size: 18, color: theme.colorScheme.onSurfaceVariant),
                        ),
                        const SizedBox(width: 8),
                        Expanded(child: Text(r, style: theme.textTheme.bodyMedium)),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ],
      ],
    );
  }

  /// Shown when a recording was cut off: what was kept, and how to go on.
  Widget _buildInterruptedCard(BuildContext context, RecordingCheckpoint cp) {
    final minutes = cp.seconds ~/ 60;
    final seconds = cp.seconds % 60;
    final length = minutes > 0 ? '$minutes min ${seconds.toString().padLeft(2, '0')} s' : '$seconds s';
    return SectionCard(
      key: const Key('recording_interrupted'),
      title: 'Recording was cut off',
      icon: Icons.history_rounded,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'The app closed while recording, at $length, last saved ${_formatClock(cp.savedAtUtc.toLocal())}. '
            'Everything captured up to then is kept, and the note below is written from it.',
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton.icon(
                key: const Key('resume_recording'),
                icon: const Icon(Icons.mic_rounded),
                label: const Text('Continue recording'),
                onPressed: _isSigned ? null : () => unawaited(_onRecordPressed()),
              ),
              OutlinedButton(
                key: const Key('dismiss_interrupted'),
                onPressed: () {
                  setState(() => _interrupted = null);
                  unawaited(_clearCheckpoint());
                },
                child: const Text('Done recording'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildAddenda(BuildContext context) {
    final theme = Theme.of(context);
    final addenda = _encounter.addenda;
    return SectionCard(
      key: const Key('addenda_card'),
      title: 'Addenda',
      icon: Icons.post_add_rounded,
      actions: [
        TextButton.icon(
          key: const Key('add_addendum'),
          onPressed: _addAddendum,
          icon: const Icon(Icons.add_rounded, size: 20),
          label: const Text('Add addendum'),
        ),
      ],
      child: addenda.isEmpty
          ? Text('None. An addendum is signed and sealed on its own and leaves the signed note unchanged.',
              style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant))
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final a in addenda)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('${_formatAddendumTime(a.atUtc)}  ${a.signerName}', style: theme.textTheme.labelLarge),
                        const SizedBox(height: 2),
                        Text(a.text, style: theme.textTheme.bodyLarge),
                        Text(
                          '${a.verify(_encounter.sha256Seal) ? 'Seal' : 'Seal does not match'} ${a.seal.substring(0, 16)}',
                          style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
    );
  }

  Widget _buildSoapSection(BuildContext context, String key, String title) {
    final theme = Theme.of(context);
    final isEditing = _editing[key] ?? false;
    final controller = _soapControllers[key]!;
    final content = controller.text;

    return SectionCard(
      title: title,
      actions: [
        TextButton.icon(
          onPressed: () => _showEvidence(title, content),
          icon: const Icon(Icons.format_quote_outlined, size: 20),
          label: const Text('Sources'),
        ),
        IconButton(
          tooltip: isEditing ? 'Save $title' : (_noteLocked ? 'Signed note is locked' : 'Edit $title'),
          icon: Icon(isEditing ? Icons.check_rounded : (_noteLocked ? Icons.lock_outline_rounded : Icons.edit_outlined)),
          color: isEditing ? theme.colorScheme.primary : null,
          onPressed: () => _toggleEdit(key),
        ),
      ],
      child: isEditing
          ? TextField(
              controller: controller,
              autofocus: true,
              minLines: 3,
              maxLines: null,
              textCapitalization: TextCapitalization.sentences,
              style: theme.textTheme.bodyLarge,
            )
          : content.trim().isEmpty
              ? Text('Nothing documented.', style: theme.textTheme.bodyLarge?.copyWith(color: theme.colorScheme.onSurfaceVariant))
              : InkWell(
                  key: Key('note_$key'),
                  onTap: () => _showEvidence(title, content),
                  child: Text.rich(_highlightUnsupported(theme, content), style: theme.textTheme.bodyLarge),
                ),
    );
  }

  /// The section text with sentences that have no source highlighted.
  TextSpan _highlightUnsupported(ThemeData theme, String content) {
    final turns = _encounter.transcript;
    if (turns.isEmpty) return TextSpan(text: content);
    final flagged = NoteSources.link(content, turns).where((l) => l.unsupported).toList();
    if (flagged.isEmpty) return TextSpan(text: content);
    final mark = SolisTheme.warning.withValues(alpha: theme.brightness == Brightness.dark ? 0.35 : 0.16);
    final spans = <TextSpan>[];
    var at = 0;
    for (final l in flagged) {
      if (l.start > at) spans.add(TextSpan(text: content.substring(at, l.start)));
      spans.add(TextSpan(
        text: content.substring(l.start, l.end),
        style: TextStyle(backgroundColor: mark, decoration: TextDecoration.underline, decorationStyle: TextDecorationStyle.dotted, decorationColor: SolisTheme.warning),
      ));
      at = l.end;
    }
    if (at < content.length) spans.add(TextSpan(text: content.substring(at)));
    return TextSpan(children: spans);
  }

  /// One-line coding summary on the note, linking to the Claim tab.
  Widget _buildCodingSummary(BuildContext context) {
    final theme = Theme.of(context);
    final claim = _claim!;
    final primary = claim.billable.isEmpty ? null : claim.billable.first;
    final pending = claim.uncertain.length;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: ListTile(
        contentPadding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
        leading: Icon(Icons.receipt_long_outlined, color: theme.colorScheme.primary),
        title: Text(primary == null ? 'No diagnosis coded yet' : '${primary.code}  ${primary.description}', maxLines: 2, overflow: TextOverflow.ellipsis),
        subtitle: Text(
          '${claim.billable.length} ${claim.billable.length == 1 ? 'diagnosis' : 'diagnoses'}, ${claim.lines.length} ${claim.lines.length == 1 ? 'service' : 'services'}'
          '${pending > 0 ? ', $pending to confirm' : ''}',
        ),
        trailing: const Icon(Icons.chevron_right_rounded),
        onTap: () => setState(() => _reviewTab = 3),
      ),
    );
  }

  Widget _buildTranscriptTab(BuildContext context) {
    final theme = Theme.of(context);
    final turns = _encounter.transcript;
    final visible = _hideSmallTalk ? turns.where((t) => !_isSmallTalk(t.text)).toList() : turns;
    final hidden = turns.length - visible.length;

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                hidden > 0 ? '${visible.length} turns, $hidden hidden' : '${turns.length} turns',
                style: theme.textTheme.titleSmall,
              ),
            ),
            FilterChip(
              label: const Text('Hide small talk'),
              selected: _hideSmallTalk,
              onSelected: (v) => setState(() => _hideSmallTalk = v),
            ),
          ],
        ),
        const SizedBox(height: 8),
        if (turns.isEmpty)
          const EmptyState(icon: Icons.forum_outlined, title: 'No transcript', message: 'Speaker turns appear here after recording.')
        else
          Card(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: Column(
                children: [
                  for (var i = 0; i < visible.length; i++) ...[
                    if (i > 0) const Divider(),
                    _TranscriptTurn(turn: visible[i], patientName: _patientName),
                  ],
                ],
              ),
            ),
          ),
        const SizedBox(height: 12),
        Card(
          clipBehavior: Clip.antiAlias,
          child: ExpansionTile(
            leading: const Icon(Icons.notes_rounded),
            title: const Text('Raw transcript'),
            subtitle: const Text('Unedited speech capture, archived with the note'),
            shape: const Border(),
            collapsedShape: const Border(),
            childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            children: [
              SelectableText(
                _transcriptController.text.trim().isEmpty ? 'Empty' : _transcriptController.text,
                style: theme.textTheme.bodyMedium,
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildOrdersTab(BuildContext context) {
    final steps = _encounter.nextSteps;
    if (steps.isEmpty) {
      return ListView(
        padding: const EdgeInsets.all(16),
        children: const [
          EmptyState(
            icon: Icons.assignment_outlined,
            title: 'No orders suggested',
            message: 'Orders, prescriptions and referrals mentioned in the visit appear here.',
          ),
        ],
      );
    }

    const groups = [
      (ActionCategory.order, 'Labs and imaging', Icons.biotech_outlined),
      (ActionCategory.prescription, 'Prescriptions', Icons.medication_outlined),
      (ActionCategory.referral, 'Referrals', Icons.person_search_outlined),
      (ActionCategory.priorAuth, 'Prior authorization', Icons.fact_check_outlined),
      (ActionCategory.billing, 'Billing checks', Icons.receipt_long_outlined),
    ];

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      children: [
        for (final (category, title, icon) in groups)
          if (steps.any((a) => a.category == category)) ...[
            SectionCard(
              title: title,
              icon: icon,
              padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
              child: Column(
                children: [
                  for (final a in _byUrgency(steps.where((a) => a.category == category))) _buildOrderRow(context, a),
                ],
              ),
            ),
            const SizedBox(height: 12),
          ],
      ],
    );
  }

  /// STAT first, then urgent, then routine. Stable within each level.
  static List<ClinicalActionItem> _byUrgency(Iterable<ClinicalActionItem> items) {
    int rank(ClinicalActionItem a) => switch (a.urgency.toLowerCase()) { 'stat' => 0, 'urgent' => 1, _ => 2 };
    final list = items.toList();
    return [for (var r = 0; r <= 2; r++) ...list.where((a) => rank(a) == r)];
  }

  Widget _buildOrderRow(BuildContext context, ClinicalActionItem a) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    void toggle(bool v) {
      if (a.isCompleted) return;
      setState(() => a.included = v);
      _persist();
    }

    return InkWell(
      borderRadius: BorderRadius.circular(SolisTheme.radiusSm),
      onTap: a.isCompleted ? null : () => toggle(!a.included),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Checkbox(
              value: a.isCompleted || a.included,
              onChanged: a.isCompleted ? null : (v) => toggle(v ?? false),
            ),
            const SizedBox(width: 4),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.only(top: 10, right: 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: Text(
                            a.title,
                            style: theme.textTheme.bodyLarge?.copyWith(
                              fontWeight: FontWeight.w600,
                              color: a.isCompleted ? cs.onSurfaceVariant : null,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        a.isCompleted
                            ? StatusTag(label: 'Marked sent', color: SolisTheme.success, icon: Icons.check_rounded)
                            : UrgencyTag(urgency: a.urgency),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(a.description, style: theme.textTheme.bodyMedium?.copyWith(color: cs.onSurfaceVariant)),
                    if (a.detailPayload != null) ...[
                      const SizedBox(height: 6),
                      Text(a.detailPayload!, style: theme.textTheme.bodySmall?.copyWith(color: cs.onSurface)),
                    ],
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// One speaker turn: role label, time, and the words, at reading size.
/// A note sentence and the conversation line it came from.
class _SentenceSourceTile extends StatelessWidget {
  final SentenceSource link;
  final SpeakerTurn? turn;
  final String patientName;

  const _SentenceSourceTile({required this.link, required this.turn, required this.patientName});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    final missing = turn == null;
    final tone = missing ? SolisTheme.onTint(SolisTheme.warning, isDark: dark) : theme.colorScheme.primary;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Icon(missing ? Icons.report_outlined : Icons.link_rounded, size: 20, color: tone),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(link.sentence, style: theme.textTheme.bodyLarge),
                const SizedBox(height: 4),
                if (missing)
                  Text('No source in the conversation', key: const Key('no_source'), style: theme.textTheme.labelMedium?.copyWith(color: tone))
                else
                  Container(
                    padding: const EdgeInsets.fromLTRB(10, 6, 10, 6),
                    decoration: BoxDecoration(
                      border: Border(left: BorderSide(color: tone, width: 3)),
                      color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
                    ),
                    child: Text.rich(
                      TextSpan(children: [
                        TextSpan(text: '${turn!.speaker}: ', style: theme.textTheme.labelLarge?.copyWith(color: tone)),
                        TextSpan(text: turn!.text),
                      ]),
                      style: theme.textTheme.bodyMedium,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _TranscriptTurn extends StatelessWidget {
  final SpeakerTurn turn;
  final String patientName;

  const _TranscriptTurn({required this.turn, required this.patientName});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    final speaker = turn.speaker.toLowerCase();
    final isDoctor = speaker == 'doctor' || speaker == 'provider';
    final isPatient = speaker == 'patient';
    final color = isDoctor ? theme.colorScheme.primary : (isPatient ? SolisTheme.onTint(SolisTheme.teal, isDark: dark) : theme.colorScheme.onSurfaceVariant);
    final label = isDoctor ? 'Doctor' : (isPatient ? 'Patient' : turn.speaker);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(label, style: theme.textTheme.labelLarge?.copyWith(color: color)),
              if (turn.timestamp.isNotEmpty) ...[
                const SizedBox(width: 8),
                Text(turn.timestamp, style: theme.textTheme.labelMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
              ],
            ],
          ),
          const SizedBox(height: 4),
          Text(turn.text, style: theme.textTheme.bodyLarge),
        ],
      ),
    );
  }
}

class _AddendumDialog extends StatefulWidget {
  const _AddendumDialog();

  @override
  State<_AddendumDialog> createState() => _AddendumDialogState();
}

class _AddendumDialogState extends State<_AddendumDialog> {
  final _c = TextEditingController();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('Add addendum'),
        content: TextField(
          key: const Key('addendum_text'),
          controller: _c,
          autofocus: true,
          minLines: 3,
          maxLines: 8,
          textCapitalization: TextCapitalization.sentences,
          decoration: const InputDecoration(hintText: 'What is being added or corrected, and why'),
          onChanged: (_) => setState(() {}),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(
            onPressed: _c.text.trim().isEmpty ? null : () => Navigator.pop(context, _c.text),
            child: const Text('Sign addendum'),
          ),
        ],
      );
}
