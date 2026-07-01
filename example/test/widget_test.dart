import 'package:camera_pro_example/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('example renders and initializes a controller', (tester) async {
    await tester.pumpWidget(const CameraProExampleApp());

    // Initially shows a loading spinner while the controller is created.
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    // After async init, the capability list and capture button appear.
    await tester.pumpAndSettle();
    expect(find.text('camera_pro'), findsOneWidget);
    expect(find.text('Capture'), findsOneWidget);
    expect(find.textContaining('Tier:'), findsOneWidget);
  });
}
