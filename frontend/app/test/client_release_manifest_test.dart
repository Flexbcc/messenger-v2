import 'package:flutter_test/flutter_test.dart';
import 'package:messenger_app/models/client_release_manifest.dart';

void main() {
  test('compareSemverBuild orders versions then build', () {
    expect(compareSemverBuild('0.1.0', 1, '0.1.1', 1), lessThan(0));
    expect(compareSemverBuild('0.2.0', 1, '0.1.9', 99), greaterThan(0));
    expect(compareSemverBuild('0.1.0', 1, '0.1.0', 2), lessThan(0));
    expect(compareSemverBuild('0.1.0', 2, '0.1.0', 2), 0);
  });

  test('isRemoteNewer detects bump', () {
    expect(
      isRemoteNewer(
        localVersion: '0.1.0',
        localBuild: 1,
        remoteVersion: '0.1.0',
        remoteBuild: 2,
      ),
      isTrue,
    );
    expect(
      isRemoteNewer(
        localVersion: '0.1.0',
        localBuild: 2,
        remoteVersion: '0.1.0',
        remoteBuild: 2,
      ),
      isFalse,
    );
  });
}
