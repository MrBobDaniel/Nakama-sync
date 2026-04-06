class AppConfig {
  const AppConfig({
    required this.navidromeBaseUrl,
    required this.navidromeUsername,
    required this.navidromePassword,
  });

  factory AppConfig.fromEnvironment() {
    return const AppConfig(
      navidromeBaseUrl: String.fromEnvironment(
        'NAKAMA_NAVIDROME_BASE_URL',
        defaultValue: '',
      ),
      navidromeUsername: String.fromEnvironment(
        'NAKAMA_NAVIDROME_USERNAME',
        defaultValue: '',
      ),
      navidromePassword: String.fromEnvironment(
        'NAKAMA_NAVIDROME_PASSWORD',
        defaultValue: '',
      ),
    );
  }

  final String navidromeBaseUrl;
  final String navidromeUsername;
  final String navidromePassword;

  bool get hasMusicConfig =>
      navidromeBaseUrl.isNotEmpty &&
      navidromeUsername.isNotEmpty &&
      navidromePassword.isNotEmpty;
}
