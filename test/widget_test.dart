import 'package:flutter_test/flutter_test.dart';

import 'package:sputni/main.dart';

void main() {
  testWidgets('home screen shows camera and monitor entry points', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const SputniApp());

    expect(find.text('Sputni'), findsOneWidget);
    expect(find.text('Open camera'), findsOneWidget);
    expect(find.text('Open monitor'), findsOneWidget);
  });
}
