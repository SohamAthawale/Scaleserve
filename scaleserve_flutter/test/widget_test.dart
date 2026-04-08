import 'package:flutter_test/flutter_test.dart';

import 'package:scaleserve_flutter/main.dart';

void main() {
  testWidgets('renders dashboard title', (WidgetTester tester) async {
    await tester.pumpWidget(
      const ScaleServeApp(
        startAutoRefresh: false,
        fetchOnStartup: false,
        requireLogin: false,
      ),
    );

    expect(find.text('ScaleServe Tailscale Controller'), findsOneWidget);
    expect(find.text('Access & Auth'), findsOneWidget);
  });
}
