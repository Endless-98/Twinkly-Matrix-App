// This is a basic Flutter widget test.
//
// To perform an interaction with a widget in your test, use the WidgetTester
// utility in the flutter_test package. For example, you can send tap and scroll
// gestures. You can also use WidgetTester to find child widgets in the widget
// tree, read text, and verify that the values of widget properties are correct.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:led_matrix_controller/main.dart';

void main() {
  testWidgets('Home page smoke test', (WidgetTester tester) async {
    // Give the test plenty of vertical space to avoid Column overflow in HomePage
    tester.view.physicalSize = const Size(1080, 1920);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    // Build our app and trigger a frame.
    await tester.pumpWidget(const ProviderScope(child: MyApp()));

    // Verify home UI renders expected labels
    expect(find.text('LED Wall Control'), findsOneWidget);
    expect(find.text('Select Mode'), findsOneWidget);
    expect(find.text('Games'), findsOneWidget);
    expect(find.text('Scenes'), findsOneWidget);
    expect(find.text('Mirroring'), findsOneWidget);
  });
}
