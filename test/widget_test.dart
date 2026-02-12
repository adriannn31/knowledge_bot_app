import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:knowledge_bot_app/main.dart'; // Ensure this matches your project name

void main() {
  testWidgets('App should load and show title', (WidgetTester tester) async {
    // We changed 'MyApp' to 'KnowledgeBot' here:
    await tester.pumpWidget(const KnowledgeBot());

    // Verify that our app bar title exists
    expect(find.text('Knowledge Bot'), findsOneWidget);

    // Verify that the API key prompt appears
    expect(find.text('🔐 Secure Access'), findsOneWidget);
  });
}