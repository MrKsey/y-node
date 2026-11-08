import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:y_node/data/wiki.dart';

void main() {
  group('parseDns', () {
    const sample = '''
====== Внутрисетевые DNS ======
^ IP сервера            ^ Размещение                 ^ Администратор ^ Примечание ^
| <del>302:db60::53</del> 308:84:68:55::          | Франкфурт, Германия        |  [[user:rev|Revertron]]     | [[yggdrasil:dns:alfis|ALFIS]], OpenNIC |
| <del>300:6223::53</del> 308:25:40:bd::          | Братислава, Словакия       |  [[user:rev|Revertron]]     | ALFIS |
|215:1e33:6417:d636:c807:6985:4f4e:fda0|Украина|  [[user:ufm]]  | ALFIS, ClearNet|
''';

    test('keeps the live address and drops the retired one', () {
      final presets = WikiService.parseDns(sample);
      expect(presets.map((preset) => preset.address), [
        '308:84:68:55::',
        '308:25:40:bd::',
        '215:1e33:6417:d636:c807:6985:4f4e:fda0',
      ]);
      expect(presets.first.location, 'Франкфурт, Германия');
      expect(presets.first.admin, 'Revertron');
      expect(presets.first.note, 'ALFIS, OpenNIC');
      expect(presets.last.admin, 'ufm');
    });

    test('ignores rows without an address', () {
      expect(WikiService.parseDns('| нет адреса | где-то | - | - |'), isEmpty);
    });
  });

  group('parseServices', () {
    const sample = '''
====== Различные внутрисетевые сервисы ======

==== Torrent ====
==== Каталоги ====

^ Адрес ^  Доменное имя  ^  Администратор  ^  Комментарий  ^
|http://[321:c99a:91a1:cd2c::16]/|  rutor.ygg  |  -  | Зеркало [[http://rutor.info/|Rutor]]  |

==== GIT ====
^  Адрес  ^  Администратор  ^ Платформа ^
|http://[316:c51a:62a3:8b9::4]/|  PurpleI2P  |  Gitea  |
|http://git.ygg/|  [[user:neonxp|NeonXP]]  |  Forgejo  |

==== NTP =====
^  Адрес  ^  Администратор  ^  Размещение  ^
|[31e:ab54:6763:4517::4]|  [[user:Orbit173|Orbit173]]  |  Лелистад  |
''';

    test('turns http rows into resources', () {
      final resources = WikiService.parseServices(sample);
      expect(resources.length, 2);
      expect(resources.first.url, 'http://[321:c99a:91a1:cd2c::16]/');
      expect(resources.first.title, 'rutor.ygg');
      expect(resources.first.description, 'Каталоги');
      expect(resources.last.title, 'GIT');
    });

    test('skips rows whose host is not a Yggdrasil address', () {
      final resources = WikiService.parseServices(sample);
      expect(resources.any((item) => item.url.contains('git.ygg')), isFalse);
      expect(resources.any((item) => item.url.contains('31e:ab54')), isFalse);
    });

    test('drops duplicates', () {
      final resources = WikiService.parseServices('''
|http://[321:c99a:91a1:cd2c::16]/|  rutor.ygg  |  -  | A  |
|http://[321:c99a:91a1:cd2c::16]/|  rutor.ygg  |  -  | A  |
''');
      expect(resources.length, 1);
    });
  });

  group('isYggAddress', () {
    test('accepts 200::/7 and rejects clearnet hosts', () {
      expect(WikiService.isYggAddress('200:1234::1'), isTrue);
      expect(WikiService.isYggAddress('3ff:ffff::1'), isTrue);
      expect(WikiService.isYggAddress('321:c99a:91a1:cd2c::16'), isTrue);
      expect(WikiService.isYggAddress('400::1'), isFalse);
      expect(WikiService.isYggAddress('1ff::1'), isFalse);
      expect(WikiService.isYggAddress('yggwiki.cc'), isFalse);
      expect(WikiService.isYggAddress('2a00:1450:4010::1'), isFalse);
    });
  });

  test('the bundled DNS snapshot parses into the five servers', () {
    final file = File('assets/data/wiki_dns.txt');
    expect(file.existsSync(), isTrue);
    final presets = WikiService.parseDns(file.readAsStringSync());
    expect(presets.length, greaterThanOrEqualTo(6));
    expect(
      presets.map((preset) => preset.address),
      containsAll([
        '308:84:68:55::',
        '308:25:40:bd::',
        '308:62:45:62::',
        '308:c8:48:45::',
        '215:1e33:6417:d636:c807:6985:4f4e:fda0',
        '202:cbff:6f7f:fa95:c6e9:3768:a96e:d1c8',
      ]),
    );
    final tilde = presets.firstWhere(
      (preset) => preset.address == '202:cbff:6f7f:fa95:c6e9:3768:a96e:d1c8',
    );
    expect(tilde.location, 'tilde.horse');
    expect(tilde.note, contains('ALFIS'));
  });

  test('the built-in DNS list knows the tilde.horse resolver', () {
    expect(
      WikiService.defaultDnsPresets.map((preset) => preset.address),
      contains('202:cbff:6f7f:fa95:c6e9:3768:a96e:d1c8'),
    );
  });

  test('the bundled services snapshot yields address book entries', () {
    final file = File('assets/data/wiki_services.txt');
    expect(file.existsSync(), isTrue);
    final resources = WikiService.parseServices(file.readAsStringSync());
    expect(resources.length, greaterThan(5));
    expect(resources.every((item) => item.url.startsWith('http')), isTrue);
    expect(resources.every((item) => item.title.isNotEmpty), isTrue);
  });
}
