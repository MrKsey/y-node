import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:y_node/data/update_service.dart';

void main() {
  group('version comparison', () {
    test('a higher release wins', () {
      expect(UpdateService.isNewerVersion('v1.4.4', '1.4.3'), isTrue);
      expect(UpdateService.isNewerVersion('1.4.10', '1.4.9'), isTrue);
      expect(UpdateService.isNewerVersion('1.5', '1.4.9'), isTrue);
    });

    test('the same or an older release is not an update', () {
      expect(UpdateService.isNewerVersion('v1.4.3', '1.4.3+23'), isFalse);
      expect(UpdateService.isNewerVersion('1.4.2', '1.4.3'), isFalse);
    });

    test('a development build accepts any release', () {
      expect(UpdateService.isNewerVersion('v1.4.4', 'dev'), isTrue);
      expect(UpdateService.isNewerVersion('dev', '1.4.3'), isFalse);
    });
  });

  test('the latest release is read from GitHub', () async {
    final client = MockClient((request) async {
      expect(request.headers['User-Agent'], 'Y-Node-Android');
      return http.Response(
        jsonEncode({
          'tag_name': 'v1.4.4',
          'body': 'A new release',
          'html_url': 'https://github.com/MrKsey/y-node/releases/tag/v1.4.4',
        }),
        200,
      );
    });
    final update = await UpdateService(
      client: client,
    ).checkForUpdate(currentVersion: '1.4.3');

    expect(update, isNotNull);
    expect(update!.version, '1.4.4');
    expect(update.notes, 'A new release');
    expect(update.releaseUrl, contains('v1.4.4'));
  });

  test('an up-to-date build returns nothing', () async {
    final client = MockClient(
      (_) async => http.Response(jsonEncode({'tag_name': 'v1.4.3'}), 200),
    );
    final update = await UpdateService(
      client: client,
    ).checkForUpdate(currentVersion: '1.4.3');
    expect(update, isNull);
  });

  test('an HTTP failure is reported', () async {
    final client = MockClient((_) async => http.Response('rate limited', 403));
    expect(
      () => UpdateService(
        client: client,
      ).checkForUpdate(currentVersion: '1.4.3'),
      throwsA(isA<UpdateCheckException>()),
    );
  });
}
