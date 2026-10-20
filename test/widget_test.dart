import 'package:flutter_test/flutter_test.dart';
import 'package:solis_mobile/main.dart';

void main() {
  testWidgets('SolisApp loads initial screen smoke test', (WidgetTester tester) async {
    await tester.pumpWidget(const SolisApp());
    expect(find.text('SOLIS'), findsOneWidget);
  });
}
