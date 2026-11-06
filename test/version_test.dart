import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:solis_mobile/widgets/medical_disclaimer.dart';

void main() {
  test('About version matches pubspec.yaml', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    final m = RegExp(r'^version:\s*([0-9.]+)', multiLine: true).firstMatch(pubspec);
    expect(m, isNotNull);
    expect(solisVersion, m!.group(1));
  });
}
