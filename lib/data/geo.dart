import 'dart:math' as math;

/// A country as it appears in the public peer list.
///
/// The list groups peers by a directory named after the country, so the parser
/// only ever has a slug such as `united-states`. The table below turns that into
/// a display name and a rough centre, which is all the first ranking pass needs.
class Country {
  const Country({
    required this.slug,
    required this.code,
    required this.name,
    required this.lat,
    required this.lon,
  });

  final String slug;
  final String code;
  final String name;
  final double lat;
  final double lon;

  String get flag {
    if (code.length != 2) return '';
    const base = 0x1F1E6;
    final first = code.codeUnitAt(0) - 0x41;
    final second = code.codeUnitAt(1) - 0x41;
    if (first < 0 || first > 25 || second < 0 || second > 25) return '';
    return String.fromCharCodes([base + first, base + second]);
  }
}

/// The countries that appear in `yggdrasil-network/public-peers`, plus the ones
/// a GeoIP lookup is likely to return for a mobile user.
const List<Country> kCountries = [
  Country(
    slug: 'south-africa',
    code: 'ZA',
    name: 'South Africa',
    lat: -30.56,
    lon: 22.94,
  ),
  Country(
    slug: 'hong-kong',
    code: 'HK',
    name: 'Hong Kong',
    lat: 22.32,
    lon: 114.17,
  ),
  Country(slug: 'india', code: 'IN', name: 'India', lat: 20.59, lon: 78.96),
  Country(
    slug: 'indonesia',
    code: 'ID',
    name: 'Indonesia',
    lat: -0.79,
    lon: 113.92,
  ),
  Country(slug: 'japan', code: 'JP', name: 'Japan', lat: 36.20, lon: 138.25),
  Country(
    slug: 'philippines',
    code: 'PH',
    name: 'Philippines',
    lat: 12.88,
    lon: 121.77,
  ),
  Country(
    slug: 'singapore',
    code: 'SG',
    name: 'Singapore',
    lat: 1.35,
    lon: 103.82,
  ),
  Country(slug: 'taiwan', code: 'TW', name: 'Taiwan', lat: 23.70, lon: 120.96),
  Country(slug: 'armenia', code: 'AM', name: 'Armenia', lat: 40.07, lon: 45.04),
  Country(slug: 'austria', code: 'AT', name: 'Austria', lat: 47.52, lon: 14.55),
  Country(slug: 'belgium', code: 'BE', name: 'Belgium', lat: 50.50, lon: 4.47),
  Country(
    slug: 'bulgaria',
    code: 'BG',
    name: 'Bulgaria',
    lat: 42.73,
    lon: 25.49,
  ),
  Country(slug: 'czechia', code: 'CZ', name: 'Czechia', lat: 49.82, lon: 15.47),
  Country(slug: 'denmark', code: 'DK', name: 'Denmark', lat: 56.26, lon: 9.50),
  Country(slug: 'estonia', code: 'EE', name: 'Estonia', lat: 58.60, lon: 25.01),
  Country(slug: 'finland', code: 'FI', name: 'Finland', lat: 61.92, lon: 25.75),
  Country(slug: 'france', code: 'FR', name: 'France', lat: 46.23, lon: 2.21),
  Country(slug: 'germany', code: 'DE', name: 'Germany', lat: 51.17, lon: 10.45),
  Country(slug: 'greece', code: 'GR', name: 'Greece', lat: 39.07, lon: 21.82),
  Country(slug: 'hungary', code: 'HU', name: 'Hungary', lat: 47.16, lon: 19.50),
  Country(
    slug: 'iceland',
    code: 'IS',
    name: 'Iceland',
    lat: 64.96,
    lon: -19.02,
  ),
  Country(slug: 'ireland', code: 'IE', name: 'Ireland', lat: 53.41, lon: -8.24),
  Country(slug: 'italy', code: 'IT', name: 'Italy', lat: 41.87, lon: 12.57),
  Country(slug: 'latvia', code: 'LV', name: 'Latvia', lat: 56.88, lon: 24.60),
  Country(
    slug: 'lithuania',
    code: 'LT',
    name: 'Lithuania',
    lat: 55.17,
    lon: 23.88,
  ),
  Country(
    slug: 'luxembourg',
    code: 'LU',
    name: 'Luxembourg',
    lat: 49.82,
    lon: 6.13,
  ),
  Country(slug: 'moldova', code: 'MD', name: 'Moldova', lat: 47.41, lon: 28.37),
  Country(
    slug: 'netherlands',
    code: 'NL',
    name: 'Netherlands',
    lat: 52.13,
    lon: 5.29,
  ),
  Country(slug: 'norway', code: 'NO', name: 'Norway', lat: 60.47, lon: 8.47),
  Country(slug: 'poland', code: 'PL', name: 'Poland', lat: 51.92, lon: 19.15),
  Country(
    slug: 'portugal',
    code: 'PT',
    name: 'Portugal',
    lat: 39.40,
    lon: -8.22,
  ),
  Country(slug: 'romania', code: 'RO', name: 'Romania', lat: 45.94, lon: 24.97),
  Country(slug: 'russia', code: 'RU', name: 'Russia', lat: 61.52, lon: 105.32),
  Country(slug: 'serbia', code: 'RS', name: 'Serbia', lat: 44.02, lon: 21.01),
  Country(
    slug: 'slovakia',
    code: 'SK',
    name: 'Slovakia',
    lat: 48.67,
    lon: 19.70,
  ),
  Country(slug: 'spain', code: 'ES', name: 'Spain', lat: 40.46, lon: -3.75),
  Country(slug: 'sweden', code: 'SE', name: 'Sweden', lat: 60.13, lon: 18.64),
  Country(
    slug: 'switzerland',
    code: 'CH',
    name: 'Switzerland',
    lat: 46.82,
    lon: 8.23,
  ),
  Country(slug: 'ukraine', code: 'UA', name: 'Ukraine', lat: 48.38, lon: 31.17),
  Country(
    slug: 'united-kingdom',
    code: 'GB',
    name: 'United Kingdom',
    lat: 55.38,
    lon: -3.44,
  ),
  Country(
    slug: 'saudi-arabia',
    code: 'SA',
    name: 'Saudi Arabia',
    lat: 23.89,
    lon: 45.08,
  ),
  Country(slug: 'turkey', code: 'TR', name: 'Turkey', lat: 38.96, lon: 35.24),
  Country(slug: 'israel', code: 'IL', name: 'Israel', lat: 31.05, lon: 34.85),
  Country(
    slug: 'united-arab-emirates',
    code: 'AE',
    name: 'United Arab Emirates',
    lat: 23.42,
    lon: 53.85,
  ),
  Country(slug: 'canada', code: 'CA', name: 'Canada', lat: 56.13, lon: -106.35),
  Country(
    slug: 'united-states',
    code: 'US',
    name: 'United States',
    lat: 37.09,
    lon: -95.71,
  ),
  Country(slug: 'mexico', code: 'MX', name: 'Mexico', lat: 23.63, lon: -102.55),
  Country(
    slug: 'australia',
    code: 'AU',
    name: 'Australia',
    lat: -25.27,
    lon: 133.78,
  ),
  Country(
    slug: 'new-zealand',
    code: 'NZ',
    name: 'New Zealand',
    lat: -40.90,
    lon: 174.89,
  ),
  Country(slug: 'brazil', code: 'BR', name: 'Brazil', lat: -14.24, lon: -51.93),
  Country(slug: 'chile', code: 'CL', name: 'Chile', lat: -35.68, lon: -71.54),
  Country(
    slug: 'argentina',
    code: 'AR',
    name: 'Argentina',
    lat: -38.42,
    lon: -63.62,
  ),
  Country(
    slug: 'colombia',
    code: 'CO',
    name: 'Colombia',
    lat: 4.57,
    lon: -74.30,
  ),
  Country(slug: 'china', code: 'CN', name: 'China', lat: 35.86, lon: 104.20),
  Country(
    slug: 'south-korea',
    code: 'KR',
    name: 'South Korea',
    lat: 35.91,
    lon: 127.77,
  ),
  Country(
    slug: 'thailand',
    code: 'TH',
    name: 'Thailand',
    lat: 15.87,
    lon: 100.99,
  ),
  Country(
    slug: 'vietnam',
    code: 'VN',
    name: 'Vietnam',
    lat: 14.06,
    lon: 108.28,
  ),
  Country(
    slug: 'malaysia',
    code: 'MY',
    name: 'Malaysia',
    lat: 4.21,
    lon: 101.98,
  ),
  Country(
    slug: 'kazakhstan',
    code: 'KZ',
    name: 'Kazakhstan',
    lat: 48.02,
    lon: 66.92,
  ),
  Country(slug: 'georgia', code: 'GE', name: 'Georgia', lat: 42.32, lon: 43.36),
  Country(slug: 'belarus', code: 'BY', name: 'Belarus', lat: 53.71, lon: 27.95),
  Country(slug: 'egypt', code: 'EG', name: 'Egypt', lat: 26.82, lon: 30.80),
  Country(slug: 'nigeria', code: 'NG', name: 'Nigeria', lat: 9.08, lon: 8.68),
  Country(slug: 'kenya', code: 'KE', name: 'Kenya', lat: -0.02, lon: 37.91),
];

final Map<String, Country> _bySlug = {
  for (final country in kCountries) country.slug: country,
};

final Map<String, Country> _byCode = {
  for (final country in kCountries) country.code: country,
};

/// Aliases the peer list has used for the same country.
const Map<String, String> _slugAliases = {
  'czech-republic': 'czechia',
  'great-britain': 'united-kingdom',
  'uk': 'united-kingdom',
  'usa': 'united-states',
  'korea': 'south-korea',
  'republic-of-korea': 'south-korea',
  'uae': 'united-arab-emirates',
};

Country? countryBySlug(String slug) {
  final normalised = slug.trim().toLowerCase();
  return _bySlug[normalised] ?? _bySlug[_slugAliases[normalised] ?? ''];
}

Country? countryByCode(String code) => _byCode[code.trim().toUpperCase()];

String countryName(String slug) {
  final country = countryBySlug(slug);
  if (country != null) return country.name;
  if (slug.isEmpty) return 'Unknown';
  return slug
      .split('-')
      .map(
        (part) =>
            part.isEmpty ? part : part[0].toUpperCase() + part.substring(1),
      )
      .join(' ');
}

String countryFlag(String slug) => countryBySlug(slug)?.flag ?? '';

/// Great-circle distance in kilometres.
double distanceKm(double lat1, double lon1, double lat2, double lon2) {
  const earthRadius = 6371.0;
  final dLat = _radians(lat2 - lat1);
  final dLon = _radians(lon2 - lon1);
  final a =
      math.sin(dLat / 2) * math.sin(dLat / 2) +
      math.cos(_radians(lat1)) *
          math.cos(_radians(lat2)) *
          math.sin(dLon / 2) *
          math.sin(dLon / 2);
  return 2 * earthRadius * math.asin(math.min(1, math.sqrt(a)));
}

double _radians(double degrees) => degrees * math.pi / 180.0;
