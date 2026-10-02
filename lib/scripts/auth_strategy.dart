import 'package:http/http.dart' as http;

import 'campus_dual_manager.models.dart';

/// Outcome of [AuthStrategy.login].
class AuthSession {
  /// Authenticated client whose jar the rest of the scrapers can ride on.
  final http.Client client;

  /// Persistent user info that the body screens rely on (hash for query params).
  final UserCredentials credentials;

  const AuthSession({required this.client, required this.credentials});
}

/// Pluggable login backend.
///
/// [AuthBackend.opal] is the default - it captures the SAML/launchpad
/// session via an in-app WebView and replays the cookies on subsequent
/// launches. [AuthBackend.sap] remains as an opt-in for users that still
/// need the self-service portal scrapers.
abstract class AuthStrategy {
  String get name;

  /// Perform the login handshake and return an [AuthSession].
  ///
  /// Implementations may throw if credentials are wrong, the IdP is
  /// unreachable, or the post-login state cannot be resolved.
  Future<AuthSession> login({String? username, String? password});
}

/// Which login backend the user has selected.
enum AuthBackend {
  sap,
  opal,
}

extension AuthBackendX on AuthBackend {
  String get displayName {
    switch (this) {
      case AuthBackend.sap:
        return "Campus Dual (klassisch)";
      case AuthBackend.opal:
        return "Campus Dual (neu, seit 2026)";
    }
  }

  /// Short subtitle for the picker in Settings.
  String get displaySubtitle {
    switch (this) {
      case AuthBackend.sap:
        return "Nur Benutzername + Passwort; ohne Passkey";
      case AuthBackend.opal:
        return "Anmeldung im Browser; passkeys moeglich";
    }
  }
}