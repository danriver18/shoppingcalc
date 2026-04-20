import 'package:flutter_test/flutter_test.dart';

import 'package:shoppingcalc/main.dart';

void main() {
  testWidgets('App boots with appbar and totals footer', (WidgetTester tester) async {
    await tester.pumpWidget(const ShoppingCalcApp());
    await tester.pump();

    expect(find.text('Mi Compra'), findsOneWidget);
    expect(find.text('TOTAL'), findsOneWidget);
  });
}
