import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/screens/main_screen.dart';

void main() {
  group('bottom-nav label breakpoint (L-48)', () {
    test('below 400 dp the labels hide whatever the setting says', () {
      expect(MainScreen.hideNavLabelsForWidth(320, showLabelsSetting: true), isTrue);
      expect(MainScreen.hideNavLabelsForWidth(360, showLabelsSetting: true), isTrue);
      expect(MainScreen.hideNavLabelsForWidth(399, showLabelsSetting: true), isTrue);
    });

    test('at 400 dp and up the setting decides', () {
      expect(MainScreen.hideNavLabelsForWidth(400, showLabelsSetting: true), isFalse);
      expect(MainScreen.hideNavLabelsForWidth(800, showLabelsSetting: true), isFalse);
      expect(MainScreen.hideNavLabelsForWidth(800, showLabelsSetting: false), isTrue,
          reason: 'the user can still hide labels on a wide screen');
      expect(MainScreen.hideNavLabelsForWidth(320, showLabelsSetting: false), isTrue);
    });
  });
}
