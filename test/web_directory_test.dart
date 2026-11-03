import 'package:flutter_test/flutter_test.dart';
import 'package:y_node/data/native.dart';
import 'package:y_node/data/web_directory.dart';

void main() {
  group('WebDirectory', () {
    const base = 'http://[21e:a51c:885b:7db0:166e:927:98cd:d186]/';

    test('reads the description and the domain of a table row', () {
      const html = '''
        <html><body>
        <table><tbody>
        <tr><td class="addr ui-table-priority-critical"><div class="n0rma1">
          <a href="http://[321:c99a:91a1:cd2c::18]/">http://[321:c99a:91a1:cd2c::18]/</a>
        </div></td><td class="descr ui-table-priority-critical"><div class="n0rma1">
          Зеркало rutracker.org
        </div></td><td class="dname ui-table-priority-critical"><div class="n0rma1">
          <a href="http://rutracker.ygg/">rutracker.ygg</a>
        </div></td><td class="dname ui-table-priority-1"></td></tr>
        <tr><td class="addr"><a href="http://[324:71e:281a:9ed3::ace]/">x</a></td>
          <td class="descr">Acetone's homepage</td><td class="dname"></td></tr>
        </tbody></table>
        </body></html>
      ''';
      final items = WebDirectory.parse(html, baseUrl: base);
      expect(items.length, 2);
      expect(items.first.title, 'Зеркало rutracker.org');
      expect(items.first.description, 'rutracker.ygg');
      expect(items.first.url, 'http://[321:c99a:91a1:cd2c::18]/');
      expect(items[1].title, "Acetone's homepage");
      expect(items[1].description, isEmpty);
    });

    test('a table row without a description falls back to the domain', () {
      const html = '''
        <table><tbody>
        <tr><td class="addr"><a href="http://[200:1::1]/">x</a></td>
          <td class="descr"></td><td class="dname">one.ygg</td></tr>
        </tbody></table>
      ''';
      final items = WebDirectory.parse(html, baseUrl: base);
      expect(items.single.title, 'one.ygg');
    });

    test('keeps Yggdrasil links and names them after the section', () {
      const html = '''
        <html><body>
        <h2>Search</h2>
        <a href="http://[200:b48d:469e:c7c7:3e13:c41d:ba4d:d2b8]/">Yggdrasil search</a>
        <a href="https://[300:ffb4:8643:34d8::f1fa:1]/speed">Speed test</a>
        <h2>Other</h2>
        <a href="http://[320:9c1:e1fa:a105::ad]/">My IP</a>
        </body></html>
      ''';
      final items = WebDirectory.parse(html, baseUrl: base);
      expect(items.length, 3);
      expect(items.first.title, 'Yggdrasil search');
      expect(items.first.description, 'Search');
      expect(items[1].url, 'https://[300:ffb4:8643:34d8::f1fa:1]/speed');
      expect(items[2].description, 'Other');
    });

    test('drops clearnet links, anchors and duplicates', () {
      const html = '''
        <a href="https://example.com/">Outside</a>
        <a href="#top">Top</a>
        <a href="mailto:someone@example.com">Mail</a>
        <a href="http://[200:1::1]/">Once</a>
        <a href="http://[200:1::1]/">Again</a>
      ''';
      final items = WebDirectory.parse(html, baseUrl: base);
      expect(items.length, 1);
      expect(items.single.url, 'http://[200:1::1]/');
    });

    test('drops the navigation of the directory itself and its assets', () {
      const html = '''
        <a href="/add_form.php">add it manually</a>
        <a href="/rss/all.xml">RSS</a>
        <a href="/style.css">Style</a>
        <a href="http://[222:a8e4:50cd:55c:788e:b0a5:4e2f:a92c]/doku.php?id=start">Wiki</a>
      ''';
      final items = WebDirectory.parse(html, baseUrl: base);
      expect(items.length, 1);
      expect(items.single.title, 'Wiki');
    });

    test('a page without links yields nothing', () {
      expect(
        WebDirectory.parse('<html><body>nothing</body></html>', baseUrl: base),
        isEmpty,
      );
    });
  });

  group('native decoders', () {
    test('DNS checks are read field by field', () {
      final checks = decodeDnsChecks(
        '[{"server":"308:84:68:55::","ok":true,"ms":12.5,'
        '"via":"udp","rcode":0,"error":""}]',
      );
      expect(checks.length, 1);
      expect(checks.single.server, '308:84:68:55::');
      expect(checks.single.ok, isTrue);
      expect(checks.single.ms, closeTo(12.5, 0.01));
      expect(checks.single.via, 'udp');
    });

    test('a broken DNS payload is an empty list', () {
      expect(decodeDnsChecks('not json'), isEmpty);
      expect(decodeDnsChecks(null), isEmpty);
    });

    test('a page payload keeps the status and the body', () {
      final page = decodeFetchResult(
        '{"status":200,"body":"<a>ok</a>","error":""}',
      );
      expect(page.ok, isTrue);
      expect(page.status, 200);
      expect(page.body, '<a>ok</a>');
    });

    test('an error payload is not ok', () {
      final page = decodeFetchResult('{"error":"the node is not running"}');
      expect(page.ok, isFalse);
      expect(page.error, 'the node is not running');
    });
  });
}
