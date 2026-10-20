// "Recent CMS updates" in the Integrations Code sets card: relevant CMS
// transmittals from solis-codesets-worker GET /v1/transmittals.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:solis_mobile/services/codesets/cms_transmittals.dart';
import 'package:solis_mobile/widgets/cms_updates_section.dart';
import 'package:solis_mobile/widgets/code_sets_card.dart';

Map<String, dynamic> _t(String id, String cr, String title, String impl, {String? url}) => {
      'id': id,
      'year': 2026,
      'title': title,
      'title_complete': true,
      'cr': cr,
      'issue_date': '2026-09-28',
      'implementation_date': impl,
      'url': url ?? 'https://www.cms.gov/medicare/regulations-guidance/transmittals/2026-transmittals/${id.toLowerCase()}',
      'pdf_url': null,
      'tags': ['edi-front-end'],
      'relevant': true,
      'replaced_by': null,
    };

final _body = jsonEncode({
  'checked_at': '2026-10-18T14:51:32.994Z',
  'errors': {},
  'total': 6,
  'transmittals': [
    _t('R13988CP', '14639', 'Annual Update of Healthcare Common Procedure Coding System (HCPCS) Codes Used for Home Health', '2027-01-04'),
    _t('R13984CP', '14640', 'Combined Common Edits/Enhancements Modules (CCEM) Code Set Update', '2027-01-04'),
    _t('R13960CP', '14618', 'Instructions for Retrieving the January 2027 Medicare Physician Fee Schedule Database (MPFSDB)', '2027-01-04'),
    _t('R13954CP', '14590', 'Internet Only Manual (IOM) Update, Publication (Pub.) 100-04, Chapter 24 General EDI', '2026-10-30'),
    _t('R13977OTN', '14429',
        'Health Insurance Portability and Accountability Act (HIPAA) Electronic Data Interchange (EDI) Front End Updates for October 2026',
        '2026-10-05'),
    _t('RBAD', '1', 'Not a CMS link', '2026-10-05', url: 'https://example.com/x'),
  ],
});

class _Recorder {
  final List<Uri> requests = [];
  int status = 200;
  late final client = CmsTransmittalsClient(
    httpClient: MockClient((req) async {
      requests.add(req.url);
      return http.Response(_body, status, headers: {'content-type': 'application/json'});
    }),
  );
}

Widget _app(Widget child, {double width = 360}) => MaterialApp(
      theme: ThemeData(useMaterial3: true, colorSchemeSeed: const Color(0xFF0B6E4F)),
      home: Scaffold(
        body: Center(child: SizedBox(width: width, child: SingleChildScrollView(child: child))),
      ),
    );

void main() {
  test('parse keeps only https://www.cms.gov links and reads CR and dates', () {
    final list = CmsTransmittalsClient.parse(_body);
    expect(list.map((t) => t.id), ['R13988CP', 'R13984CP', 'R13960CP', 'R13954CP', 'R13977OTN']);
    final edi = list.last;
    expect(edi.cr, '14429');
    expect(edi.implementationDate, DateTime(2026, 10, 5));
    expect(edi.tags, ['edi-front-end']);
    expect(() => CmsTransmittalsClient.parse('{"nope":1}'), throwsFormatException);
  });

  test('the client asks for relevant, current transmittals, top 5, and caches', () async {
    final r = _Recorder();
    final list = await r.client.recent();
    expect(list, hasLength(5));
    final q = r.requests.single;
    expect(q.toString(), startsWith('https://solis-codesets-worker.cbvarshini1.workers.dev/v1/transmittals'));
    expect(q.queryParameters, {'relevant': '1', 'current': '1', 'limit': '5'});
    await r.client.recent();
    expect(r.requests, hasLength(1), reason: 'cached');
    await r.client.recent(refresh: true);
    expect(r.requests, hasLength(2));
  });

  testWidgets('collapsed until opened; lists title, CR and implementation date; opens the CMS page', (t) async {
    final r = _Recorder();
    final opened = <String>[];
    await t.pumpWidget(_app(CmsUpdatesSection(client: r.client, openUrl: (u) async {
      opened.add(u);
      return true;
    })));
    expect(find.text('Recent CMS updates'), findsOneWidget);
    expect(r.requests, isEmpty, reason: 'no network call until opened');

    await t.tap(find.byKey(const Key('cms_updates_toggle')));
    await t.pumpAndSettle();
    expect(r.requests, hasLength(1));
    expect(find.textContaining('Front End Updates for October 2026'), findsOneWidget);
    expect(find.text('CR 14429, R13977OTN, implementation Oct 5, 2026'), findsOneWidget);
    expect(find.byKey(const Key('cms_update_RBAD')), findsNothing);
    expect(find.byIcon(Icons.open_in_new_rounded), findsNWidgets(5));

    // 48dp touch targets.
    for (final id in ['R13988CP', 'R13977OTN']) {
      expect(t.getSize(find.byKey(Key('cms_update_$id'))).height, greaterThanOrEqualTo(48));
    }
    expect(t.getSize(find.byKey(const Key('cms_updates_toggle'))).height, greaterThanOrEqualTo(48));

    // No bullet or dot glyphs.
    for (final w in t.widgetList<Text>(find.byType(Text))) {
      final s = w.data ?? w.textSpan?.toPlainText() ?? '';
      expect(s.contains(String.fromCharCode(0x2022)) || s.contains(String.fromCharCode(0x00b7)), isFalse, reason: s);
    }

    await t.tap(find.byKey(const Key('cms_update_R13977OTN')));
    await t.pump();
    expect(opened, ['https://www.cms.gov/medicare/regulations-guidance/transmittals/2026-transmittals/r13977otn']);
  });

  testWidgets('when the browser cannot open, the link is copied', (t) async {
    final r = _Recorder();
    String? copied;
    t.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') copied = (call.arguments as Map)['text'] as String?;
      return null;
    });
    addTearDown(() => t.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
    await t.pumpWidget(_app(CmsUpdatesSection(client: r.client, initiallyExpanded: true, openUrl: (_) async => false)));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('cms_update_R13984CP')));
    await t.pumpAndSettle();
    expect(copied, 'https://www.cms.gov/medicare/regulations-guidance/transmittals/2026-transmittals/r13984cp');
    expect(find.textContaining('Link to R13984CP copied'), findsOneWidget);
  });

  testWidgets('a failed load says so and retries', (t) async {
    final r = _Recorder()..status = 503;
    await t.pumpWidget(_app(CmsUpdatesSection(client: r.client, initiallyExpanded: true)));
    await t.pumpAndSettle();
    expect(find.text('CMS updates could not be loaded.'), findsOneWidget);
    r.status = 200;
    await t.tap(find.text('Retry'));
    await t.pumpAndSettle();
    expect(find.textContaining('Front End Updates'), findsOneWidget);
  });

  testWidgets('the Code sets card shows the section and fits a compact phone', (t) async {
    final r = _Recorder();
    await t.pumpWidget(_app(
      CodeSetsCard(cmsUpdates: CmsUpdatesSection(client: r.client, initiallyExpanded: true, openUrl: (_) async => true)),
      width: 320,
    ));
    await t.pumpAndSettle();
    expect(find.text('Code sets'), findsOneWidget);
    expect(find.textContaining('Front End Updates'), findsOneWidget);
    expect(t.takeException(), isNull, reason: 'no overflow at 320 dp');
  });
}
