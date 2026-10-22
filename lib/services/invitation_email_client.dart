import 'dart:async';
import 'dart:convert';
import 'package:firebase_auth/firebase_auth.dart' as fb_auth;
import 'package:http/http.dart' as http;
import '../models/household_invitation_model.dart';

/// Outcome of asking the backend to email an invitation.
class InvitationEmailResult {
  /// New delivery status, or null when the request was refused without changing it
  /// (e.g. resend cooldown).
  final EmailDeliveryStatus? status;
  final String? error;

  /// Raw SMTP response from Gmail when the message was accepted (e.g. "250 2.0.0 OK ...").
  final String? providerResponse;
  final bool alreadySent;

  const InvitationEmailResult({
    this.status,
    this.error,
    this.providerResponse,
    this.alreadySent = false,
  });
}

/// Sends the email for an invitation that already exists in Firestore.
abstract class InvitationEmailSender {
  Future<InvitationEmailResult> sendInvitationEmail(String invitationId, {bool resend = false});
}

/// Talks to the local Node backend in `server/` (Express + Nodemailer + Gmail SMTP).
/// The app never holds email credentials; it only proves who the user is with their
/// Firebase ID token.
class BackendInvitationEmailSender implements InvitationEmailSender {
  /// Override with `--dart-define=INVITE_API_BASE_URL=http://host:port`.
  static const String _configuredBaseUrl = String.fromEnvironment('INVITE_API_BASE_URL');

  final http.Client _client;
  final Future<String?> Function() _idTokenProvider;
  final String baseUrl;
  final Duration timeout;

  BackendInvitationEmailSender({
    http.Client? client,
    Future<String?> Function()? idTokenProvider,
    String? baseUrl,
    this.timeout = const Duration(seconds: 45),
  })  : _client = client ?? http.Client(),
        _idTokenProvider = idTokenProvider ?? _firebaseIdToken,
        baseUrl = _trimSlash(baseUrl ?? defaultBaseUrl());

  static String _trimSlash(String s) => s.endsWith('/') ? s.substring(0, s.length - 1) : s;

  /// Defaults to the deployed Vercel server. Override with
  /// `--dart-define=INVITE_API_BASE_URL=https://your-custom-url`.
  static String defaultBaseUrl() {
    if (_configuredBaseUrl.isNotEmpty) return _configuredBaseUrl;
    return 'https://vanity-tracker-server.vercel.app';
  }

  static Future<String?> _firebaseIdToken() async {
    return fb_auth.FirebaseAuth.instance.currentUser?.getIdToken();
  }

  @override
  Future<InvitationEmailResult> sendInvitationEmail(String invitationId, {bool resend = false}) async {
    final String? token;
    try {
      token = await _idTokenProvider();
    } catch (e) {
      return InvitationEmailResult(
        status: EmailDeliveryStatus.failed,
        error: 'Could not get your sign-in token to authorize the email: $e',
      );
    }
    if (token == null || token.isEmpty) {
      return const InvitationEmailResult(
        status: EmailDeliveryStatus.failed,
        error: 'You must be signed in with Firebase to send invitation emails.',
      );
    }

    final uri = Uri.parse('$baseUrl/api/invitations/${Uri.encodeComponent(invitationId)}/send');
    http.Response res;
    try {
      res = await _client
          .post(
            uri,
            headers: {
              'Authorization': 'Bearer $token',
              'Content-Type': 'application/json',
            },
            body: jsonEncode({'resend': resend}),
          )
          .timeout(timeout);
    } on TimeoutException {
      return InvitationEmailResult(
        status: EmailDeliveryStatus.failed,
        error: 'The invitation email server at $baseUrl did not respond in time.',
      );
    } catch (_) {
      return InvitationEmailResult(
        status: EmailDeliveryStatus.failed,
        error: 'Could not reach the invitation email server at $baseUrl. '
            'Please verify your network connection or check the server status at /api/health.',
      );
    }

    Map<String, dynamic> body = const {};
    try {
      final decoded = jsonDecode(res.body);
      if (decoded is Map<String, dynamic>) body = decoded;
    } catch (_) {
      // Non-JSON response; handled below.
    }
    final errorMap = body['error'];
    final message = errorMap is Map ? errorMap['message']?.toString() : null;

    if (res.statusCode == 200 && body['emailStatus'] == 'sent') {
      return InvitationEmailResult(
        status: EmailDeliveryStatus.sent,
        providerResponse: body['providerResponse']?.toString(),
        alreadySent: body['alreadySent'] == true,
      );
    }

    final reported = body['emailStatus']?.toString();
    if (reported == 'notConfigured') {
      return InvitationEmailResult(
        status: EmailDeliveryStatus.notConfigured,
        error: message ?? 'Email sending is not configured on the backend.',
      );
    }
    if (reported == 'failed') {
      return InvitationEmailResult(
        status: EmailDeliveryStatus.failed,
        error: message ?? 'The email could not be sent.',
      );
    }
    // Refused before any send attempt (auth, permission, cooldown, invalid state).
    // Cooldown / in-progress leave the stored status as it is.
    final code = errorMap is Map ? errorMap['code']?.toString() : null;
    final keepStatus = code == 'cooldown' || code == 'in-progress';
    return InvitationEmailResult(
      status: keepStatus ? null : EmailDeliveryStatus.failed,
      error: message ?? 'Email server returned HTTP ${res.statusCode}.',
    );
  }
}
