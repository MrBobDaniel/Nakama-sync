class AppConfig {
  const AppConfig({
    required this.navidromeBaseUrl,
    required this.navidromeUsername,
    required this.navidromePassword,
    required this.signalingServerUrl,
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
      signalingServerUrl: String.fromEnvironment(
        'NAKAMA_SIGNALING_URL',
        defaultValue: 'http://localhost:3000',
      ),
    );
  }

  final String navidromeBaseUrl;
  final String navidromeUsername;
  final String navidromePassword;
  final String signalingServerUrl;

  bool get hasMusicConfig =>
      navidromeBaseUrl.isNotEmpty &&
      navidromeUsername.isNotEmpty &&
      navidromePassword.isNotEmpty;
}
