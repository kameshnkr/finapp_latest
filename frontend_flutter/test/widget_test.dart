import 'package:flutter_test/flutter_test.dart';

import 'package:finapp/main.dart';

void main() {
  testWidgets('App builds', (WidgetTester tester) async {
    await tester.pumpWidget(const FinappApp());
    expect(find.text('Finapp'), findsOneWidget);
  });
}
