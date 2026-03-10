import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:veea_tag_app/main.dart';
import 'package:veea_tag_app/services/find_my_device_service.dart';

void main() {
  testWidgets('App launches', (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});
    final findMyService = FindMyDeviceService();
    await findMyService.load();
    await tester.pumpWidget(VeeaTagApp(findMyService: findMyService));
    expect(find.text('Veea Tag'), findsOneWidget);
  });
}
