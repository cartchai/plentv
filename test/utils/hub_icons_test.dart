// hubIconFor keyword matching — the Home favourites hub (1.6.25) is
// titled "Favourites" and must get the heart, not the default sparkle.
import 'package:flutter_test/flutter_test.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:plezy/media/media_hub.dart';
import 'package:plezy/utils/hub_icons.dart';

void main() {
  test('a Favourites hub gets the heart icon', () {
    const hub = MediaHub(id: 'favorites', title: 'Favourites', type: 'mixed', items: []);
    expect(hubIconFor(hub), Symbols.favorite_rounded);
  });

  test('the American spelling matches too', () {
    const hub = MediaHub(id: 'favorites', title: 'Favorites', type: 'mixed', items: []);
    expect(hubIconFor(hub), Symbols.favorite_rounded);
  });

  test('unmatched hubs keep the default icon', () {
    const hub = MediaHub(id: 'x', title: 'Something Else', type: 'movie', items: []);
    expect(hubIconFor(hub), Symbols.auto_awesome_rounded);
  });
}
