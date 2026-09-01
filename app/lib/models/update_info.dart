/// 应用内版本更新数据模型（M1.1）。
///
/// 数据源：GitHub Releases API（`/repos/{owner}/{repo}/releases/latest`）。
/// MVP 简化：只发 arm64-v8a，所以 [apkUrl] 是单值；多 ABI 字段后续扩展。
///
/// 设计要点：
/// - [isNewerThan] 双保险：先比 semver 三段，再比 [code]（防 semver 字符串
///   解析误判，比如 `2.10.0` < `2.9.0` 这种字符串比较陷阱）。两者都大才
///   返回 true；相等或更小都返回 false。
/// - [isMandatory] 走 [minSupportedCode]（强制更新阈值），首版不启用。
library;

class UpdateInfo {
  /// 主版本号（如 "2.14.0"），无 `v` 前缀。
  final String version;

  /// Android versionCode（递增数字）。
  final int code;

  /// 强制更新阈值：当前 [code] 严格小于该值时必须升级。
  /// null 表示当前版本没有强制更新要求。
  final int? minSupportedCode;

  /// 更新日志（markdown / 纯文本，UI 自行渲染）。
  final String changelog;

  /// APK 下载地址（MVP：单 ABI，arm64-v8a）。
  final String apkUrl;

  /// APK 期望 SHA-256（十六进制小写）。null 时跳过完整性校验。
  final String? sha256;

  /// APK 字节数（仅供 UI 展示进度参考）。
  final int? size;

  const UpdateInfo({
    required this.version,
    required this.code,
    required this.apkUrl,
    this.minSupportedCode,
    this.changelog = '',
    this.sha256,
    this.size,
  });

  /// 是否比当前版本新。双保险：semver 三段全比 + code 数字比。
  ///
  /// 任一比较维度更大即视为更新（避免 semver 字符串被 `2.10.0` 解析异常）。
  /// 两者都小或相等 → false。
  bool isNewerThan(String currentVersion, int currentCode) {
    if (code != currentCode) return code > currentCode;
    // code 相等时退化为 semver 三段比（任一段更大即视为更新）。
    final a = _parseSemver(currentVersion);
    final b = _parseSemver(version);
    if (a == null || b == null) {
      // 解析失败时保守：code 相等即视为不新，避免误弹。
      return false;
    }
    for (var i = 0; i < 3; i++) {
      if (b[i] != a[i]) return b[i] > a[i];
    }
    return false;
  }

  /// 当前是否低于强制更新阈值。
  bool isMandatory(int currentCode) =>
      minSupportedCode != null && currentCode < minSupportedCode!;

  /// 把 semver 主版本号拆成 3 段整数。解析失败返回 null。
  static List<int>? _parseSemver(String v) {
    final parts = v.split('.');
    if (parts.length < 3) return null;
    final out = <int>[];
    for (var i = 0; i < 3; i++) {
      final n = int.tryParse(parts[i]);
      if (n == null) return null;
      out.add(n);
    }
    return out;
  }

  /// 从 GitHub Releases `/releases/latest` JSON 构造。
  ///
  /// 解析约定：
  /// - `tag_name` 去 `v` 前缀作为 [version]
  /// - 从 `assets[]` 筛出 `name` 含 `arm64-v8a` 的第一个 → `apkUrl`
  /// - 同上资产的 `digest` 形如 `sha256:abc...`，取十六进制部分作为 [sha256]
  /// - `body` 作为 [changelog]
  /// - `size` / `minSupportedCode` 优先从 `assets[].size` / Release 元数据
  ///   （自定义 `min_supported_code`）读，缺失时为 null
  ///
  /// 解析失败（缺 tag / 无 arm64 资产等）抛 [FormatException]，由
  /// [UpdateService] 捕获后包装为 [UpdateException] 抛出。
  factory UpdateInfo.fromGitHubReleaseJson(Map<String, dynamic> json) {
    final tag = (json['tag_name'] as String?) ?? '';
    if (tag.isEmpty) {
      throw const FormatException('GitHub Release 缺少 tag_name');
    }
    // 去 `v` 前缀与 `+数字` 后缀（pub-style tag 写法）
    var versionRaw = tag.startsWith('v') ? tag.substring(1) : tag;
    final plusIdx = versionRaw.indexOf('+');
    final version =
        plusIdx >= 0 ? versionRaw.substring(0, plusIdx) : versionRaw;
    final code = _parseCodeFromTag(tag, json);
    if (code == null) {
      throw FormatException('无法从 tag_name=$tag 解析 versionCode');
    }
    final minCode = (json['min_supported_code'] as num?)?.toInt();

    final assets = (json['assets'] as List?) ?? const [];
    Map<String, dynamic>? armAsset;
    for (final raw in assets) {
      if (raw is! Map) continue;
      final name = (raw['name'] as String?) ?? '';
      if (name.contains('arm64-v8a')) {
        armAsset = raw.cast<String, dynamic>();
        break;
      }
    }
    if (armAsset == null) {
      throw const FormatException('GitHub Release assets 缺少 arm64-v8a APK');
    }
    final browserUrl = armAsset['browser_download_url'] as String? ?? '';
    if (browserUrl.isEmpty) {
      throw const FormatException('arm64-v8a asset 缺少 browser_download_url');
    }
    String? sha256;
    final digest = armAsset['digest'] as String?;
    if (digest != null && digest.startsWith('sha256:')) {
      sha256 = digest.substring('sha256:'.length).toLowerCase();
    }
    final size = (armAsset['size'] as num?)?.toInt();

    return UpdateInfo(
      version: version,
      code: code,
      minSupportedCode: minCode,
      changelog: (json['body'] as String?) ?? '',
      apkUrl: browserUrl,
      sha256: sha256,
      size: size,
    );
  }

  /// 从 `tag_name`（如 `v2.14.0` 或 `v2.14.0+26`）取 versionCode。
  ///
  /// 优先解析 `+数字` 后缀；其次尝试读 `name` 字段的 `+数字` 后缀；
  /// 都没有时按 [fallback]（从 assets 读）走；都没有就返回 null。
  static int? _parseCodeFromTag(String tag, Map<String, dynamic> json) {
    final plusIdx = tag.indexOf('+');
    if (plusIdx >= 0 && plusIdx < tag.length - 1) {
      final n = int.tryParse(tag.substring(plusIdx + 1));
      if (n != null) return n;
    }
    final name = (json['name'] as String?) ?? '';
    final namePlus = name.indexOf('+');
    if (namePlus >= 0 && namePlus < name.length - 1) {
      final n = int.tryParse(name.substring(namePlus + 1));
      if (n != null) return n;
    }
    // 兜底：用发布日期的年份后两位 + 月日（如 2026-09-01 → 260901），保证唯一。
    final published = json['published_at'] as String?;
    if (published != null && published.length >= 10) {
      final year2 = published.substring(2, 4);
      final month = published.substring(5, 7);
      final day = published.substring(8, 10);
      return int.tryParse('$year2$month$day');
    }
    return null;
  }
}

/// 应用内更新业务异常。message 设计为可直接 SnackBar 展示。
class UpdateException implements Exception {
  final String message;
  const UpdateException(this.message);

  @override
  String toString() => 'UpdateException: $message';
}
