// UpdateInfo 模型单元测试（M1.1）：
// - fromGitHubReleaseJson：tag / assets / digest 解析
// - isNewerThan：semver 三段 + code 双保险
// - isMandatory：minSupportedCode 阈值
// - 解析失败抛 FormatException
import 'package:flutter_test/flutter_test.dart';

import 'package:bili_whitelist_app/models/update_info.dart';

void main() {
  group('fromGitHubReleaseJson', () {
    test('完整 GitHub Release JSON 解析正确', () {
      final json = {
        'tag_name': 'v2.14.0',
        'name': 'v2.14.0+26',
        'body': '## v2.14.0\n- 新增应用内更新',
        'published_at': '2026-09-01T10:00:00Z',
        'assets': [
          {
            'name': 'app-arm64-v8a-v2.14.0-release.apk',
            'browser_download_url':
                'https://github.com/Tukist/bili-whitelist/releases/download/v2.14.0/app-arm64-v8a-v2.14.0-release.apk',
            'size': 12345678,
            'digest': 'sha256:abc123def456789',
          },
          {
            'name': 'app-armeabi-v7a-v2.14.0-release.apk',
            'browser_download_url': 'https://example.com/old.apk',
          },
        ],
      };
      final info = UpdateInfo.fromGitHubReleaseJson(json);
      expect(info.version, '2.14.0');
      // 优先从 tag_name 解析 +26
      expect(info.code, 26);
      expect(info.apkUrl, contains('arm64-v8a'));
      expect(info.apkUrl, isNot(contains('armeabi')));
      expect(info.sha256, 'abc123def456789');
      expect(info.size, 12345678);
      expect(info.changelog, contains('应用内更新'));
      expect(info.minSupportedCode, isNull);
    });

    test('tag_name 无 v 前缀也能解析', () {
      final json = {
        'tag_name': '2.14.0+26',
        'assets': [
          {
            'name': 'app-arm64-v8a-v2.14.0-release.apk',
            'browser_download_url': 'https://example.com/a.apk',
          },
        ],
      };
      final info = UpdateInfo.fromGitHubReleaseJson(json);
      expect(info.version, '2.14.0');
      expect(info.code, 26);
    });

    test('缺少 arm64-v8a asset 抛 FormatException', () {
      final json = {
        'tag_name': 'v2.14.0',
        'assets': [
          {
            'name': 'app-armeabi-v7a-v2.14.0-release.apk',
            'browser_download_url': 'https://example.com/x.apk',
          },
        ],
      };
      expect(
        () => UpdateInfo.fromGitHubReleaseJson(json),
        throwsFormatException,
      );
    });

    test('缺少 tag_name 抛 FormatException', () {
      final json = {'assets': []};
      expect(
        () => UpdateInfo.fromGitHubReleaseJson(json),
        throwsFormatException,
      );
    });

    test('digest 无 sha256: 前缀时 sha256 为 null', () {
      final json = {
        'tag_name': 'v2.14.0+26',
        'assets': [
          {
            'name': 'app-arm64-v8a-v2.14.0-release.apk',
            'browser_download_url': 'https://example.com/a.apk',
            'digest': 'md5:zzz',
          },
        ],
      };
      final info = UpdateInfo.fromGitHubReleaseJson(json);
      expect(info.sha256, isNull);
    });

    test('min_supported_code 自定义字段可解析', () {
      final json = {
        'tag_name': 'v2.14.0+26',
        'min_supported_code': 20,
        'assets': [
          {
            'name': 'app-arm64-v8a-v2.14.0-release.apk',
            'browser_download_url': 'https://example.com/a.apk',
          },
        ],
      };
      final info = UpdateInfo.fromGitHubReleaseJson(json);
      expect(info.minSupportedCode, 20);
    });
  });

  group('isNewerThan', () {
    UpdateInfo info({int code = 26, String version = '2.14.0'}) => UpdateInfo(
          version: version,
          code: code,
          apkUrl: 'https://example.com/a.apk',
        );

    test('code 严格大于 → 新', () {
      expect(info().isNewerThan('2.14.0', 25), isTrue);
    });

    test('code 严格小于 → 不新', () {
      expect(info().isNewerThan('2.14.0', 27), isFalse);
    });

    test('code 相等但 semver 大 → 新（2.14.0 > 2.13.9）', () {
      expect(info().isNewerThan('2.13.9', 26), isTrue);
    });

    test('code 相等且 semver 相等 → 不新', () {
      expect(info().isNewerThan('2.14.0', 26), isFalse);
    });

    test('code 相等但 semver 小 → 不新', () {
      expect(info().isNewerThan('2.14.1', 26), isFalse);
    });

    test('semver 字符串比较陷阱：2.10.0 > 2.9.0', () {
      // 如果按字符串比会判错，模型要按数值比。
      expect(info(version: '2.10.0').isNewerThan('2.9.0', 26), isTrue);
    });

    test('semver 解析失败且 code 相等 → 视为不新', () {
      expect(info().isNewerThan('bad', 26), isFalse);
    });
  });

  group('isMandatory', () {
    test('currentCode < minSupportedCode → 强制', () {
      final info = UpdateInfo(
        version: '2.14.0',
        code: 27,
        minSupportedCode: 25,
        apkUrl: 'https://x',
      );
      expect(info.isMandatory(24), isTrue);
    });

    test('currentCode >= minSupportedCode → 不强制', () {
      final info = UpdateInfo(
        version: '2.14.0',
        code: 27,
        minSupportedCode: 25,
        apkUrl: 'https://x',
      );
      expect(info.isMandatory(25), isFalse);
      expect(info.isMandatory(30), isFalse);
    });

    test('minSupportedCode 为 null → 永不强制', () {
      const info = UpdateInfo(
        version: '2.14.0',
        code: 27,
        apkUrl: 'https://x',
      );
      expect(info.isMandatory(1), isFalse);
    });
  });
}
