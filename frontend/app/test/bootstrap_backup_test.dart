// Post-R5 client backup bootstrap URLs (docs/reality/R4-routing.md, "Нет
// client backup routes"). Covers NetworkBootstrap parsing/persistence shape
// only — network calls (BootstrapService.fetchRouting/redeemInvite) are not
// exercised here.
import 'package:flutter_test/flutter_test.dart';
import 'package:messenger_app/services/bootstrap_service.dart';

void main() {
  group('extractBackupHomeUrls', () {
    test('collects alternate home_nodes excluding the primary', () {
      final routing = {
        'home_nodes': [
          {
            'node_id': 'h1',
            'url': 'https://home-1.example',
            'latency_ms': 12.0,
          },
          {
            'node_id': 'h2',
            'url': 'https://home-2.example',
            'latency_ms': 40.0,
          },
        ],
      };
      final backups = extractBackupHomeUrls(routing, 'https://home-1.example');
      expect(backups, ['https://home-2.example']);
    });

    test('returns empty list when routing has no home_nodes', () {
      expect(
        extractBackupHomeUrls({'discovery_url': 'https://d'}, 'https://home'),
        isEmpty,
      );
      expect(extractBackupHomeUrls(null, 'https://home'), isEmpty);
    });

    test('dedupes and drops empty urls', () {
      final routing = {
        'home_nodes': [
          {'node_id': 'h2', 'url': 'https://home-2.example'},
          {'node_id': 'h2dup', 'url': 'https://home-2.example'},
          {'node_id': 'h3', 'url': ''},
        ],
      };
      final backups = extractBackupHomeUrls(routing, 'https://home-1.example');
      expect(backups, ['https://home-2.example']);
    });
  });

  group('NetworkBootstrap', () {
    test(
      'fromJson derives backups from nested routing (invite redeem shape)',
      () {
        final bootstrap = NetworkBootstrap.fromJson({
          'cluster_id': 'default',
          'gateway_url': 'https://gw.example',
          'discovery_url': 'https://disc.example',
          'home_url': 'https://home-1.example',
          'media_url': 'https://media.example',
          'routing': {
            'home_nodes': [
              {'node_id': 'h1', 'url': 'https://home-1.example'},
              {'node_id': 'h2', 'url': 'https://home-2.example'},
            ],
          },
        });
        expect(bootstrap.homeUrl, 'https://home-1.example');
        expect(bootstrap.backupHomeUrls, ['https://home-2.example']);
        expect(
          bootstrap.allHomeUrls,
          containsAll(['https://home-1.example', 'https://home-2.example']),
        );
      },
    );

    test(
      'fromJson derives backups from top-level home_nodes (GET /gateway/routing shape)',
      () {
        final bootstrap = NetworkBootstrap.fromJson({
          'cluster_id': 'default',
          'gateway_url': 'https://gw.example',
          'discovery_url': 'https://disc.example',
          'home_url': 'https://home-1.example',
          'media_url': 'https://media.example',
          'home_nodes': [
            {'node_id': 'h1', 'url': 'https://home-1.example'},
            {'node_id': 'h2', 'url': 'https://home-2.example'},
          ],
        });
        expect(bootstrap.backupHomeUrls, ['https://home-2.example']);
      },
    );

    test(
      'round-trips backupHomeUrls through toJson/fromJson (persisted shape)',
      () {
        const original = NetworkBootstrap(
          clusterId: 'default',
          gatewayUrl: 'https://gw.example',
          discoveryUrl: 'https://disc.example',
          homeUrl: 'https://home-1.example',
          mediaUrl: 'https://media.example',
          backupHomeUrls: ['https://home-2.example', 'https://home-3.example'],
        );
        final reloaded = NetworkBootstrap.fromJson(original.toJson());
        expect(reloaded.backupHomeUrls, original.backupHomeUrls);
      },
    );

    test('fromJson is backward compatible with pre-backup persisted JSON', () {
      final bootstrap = NetworkBootstrap.fromJson({
        'cluster_id': 'default',
        'gateway_url': 'https://gw.example',
        'discovery_url': 'https://disc.example',
        'home_url': 'https://home-1.example',
        'media_url': 'https://media.example',
      });
      expect(bootstrap.backupHomeUrls, isEmpty);
      expect(bootstrap.homeUrl, 'https://home-1.example');
    });

    test('copyWith updates backups without touching primary home', () {
      const original = NetworkBootstrap(
        clusterId: 'default',
        gatewayUrl: 'https://gw.example',
        discoveryUrl: 'https://disc.example',
        homeUrl: 'https://home-1.example',
        mediaUrl: 'https://media.example',
      );
      final updated = original.copyWith(
        backupHomeUrls: ['https://home-2.example'],
      );
      expect(updated.homeUrl, original.homeUrl);
      expect(updated.backupHomeUrls, ['https://home-2.example']);
    });
  });
}
