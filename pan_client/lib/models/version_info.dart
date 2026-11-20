class VersionInfo {
  final String latestVersion;
  final String minSupportVersion;
  final String updateUrl;
  final String updateLog;
  final bool forceUpdate;

  VersionInfo({
    required this.latestVersion,
    required this.minSupportVersion,
    required this.updateUrl,
    required this.updateLog,
    required this.forceUpdate,
  });

  factory VersionInfo.fromJson(Map<String, dynamic> json) {
    return VersionInfo(
      latestVersion: json['latest_version'] ?? '1.0.0',
      minSupportVersion: json['min_support_version'] ?? '1.0.0',
      updateUrl: json['update_url'] ?? '',
      updateLog: json['update_log'] ?? '',
      forceUpdate: json['force_update'] ?? false,
    );
  }
}