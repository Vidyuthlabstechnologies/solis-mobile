import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:solis_mobile/screens/integrations_screen.dart';
import 'package:solis_mobile/services/billing/integration_settings.dart';
import 'package:solis_mobile/services/integrations.dart';

void main() {
  setUp(() => Integrations.settings = IntegrationSettings.inMemory());

  Future<void> open(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 2.5;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const MaterialApp(home: IntegrationsScreen()));
    await tester.pump();
  }

  testWidgets('switching to Production asks first, and Stay on test keeps test claims', (tester) async {
    await open(tester);
    await tester.tap(find.text('Production'));
    await tester.pumpAndSettle();
    expect(find.text('Send real claims?'), findsOneWidget);
    await tester.tap(find.text('Stay on test'));
    await tester.pumpAndSettle();
    expect(find.text('Claims are marked as test (T) and are not paid.'), findsOneWidget);

    await tester.tap(find.text('Production'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Use production'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Claims go to payers for payment (P).'), findsOneWidget);

    // Back to test needs no confirmation.
    await tester.tap(find.text('Test claims'));
    await tester.pumpAndSettle();
    expect(find.text('Send real claims?'), findsNothing);
    expect(find.text('Claims are marked as test (T) and are not paid.'), findsOneWidget);
  });
}
