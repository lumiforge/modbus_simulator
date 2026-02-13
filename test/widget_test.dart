import 'package:flutter_test/flutter_test.dart';
import 'package:modbus_simulator/main.dart';

void main() {
  testWidgets('renders control panel basics', (WidgetTester tester) async {
    await tester.pumpWidget(const ModbusSimulatorApp());

    expect(find.text('Modbus TCP Server Simulator'), findsOneWidget);
    expect(find.text('Holding registers'), findsOneWidget);
    expect(find.text('Request log'), findsOneWidget);
  });
}
