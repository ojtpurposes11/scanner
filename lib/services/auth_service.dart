import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';

class AuthService {
  final FirebaseAuth _auth = FirebaseAuth.instance;

  // Allowed credentials fetched from environment variables
  static Map<String, String> get _credentials => {
    dotenv.env['ADMIN_EMAIL'] ?? '': dotenv.env['ADMIN_PASSWORD'] ?? '',
    dotenv.env['FIELD_EMAIL'] ?? '': dotenv.env['FIELD_PASSWORD'] ?? '',
  };

  // Each email is locked to exactly one role
  static Map<String, String> get _roles => {
    dotenv.env['ADMIN_EMAIL'] ?? '': 'Admin',
    dotenv.env['FIELD_EMAIL'] ?? '': 'Field Collector',
  };

  Future<Map<String, dynamic>> signIn(
    String email,
    String password, {
    String? attemptedRole,
  }) async {
    final normalizedEmail = email.trim().toLowerCase();

    // ── Step 1: Check credentials are known ──
    if (!_credentials.containsKey(normalizedEmail) ||
        _credentials[normalizedEmail] != password) {
      await _auth.signOut();
      return {'success': false, 'error': 'Invalid username or password.'};
    }

    // ── Step 2: Enforce role lock ──
    final assignedRole = _roles[normalizedEmail]!;
    if (attemptedRole != null && assignedRole != attemptedRole) {
      await _auth.signOut();
      return {
        'success': false,
        'error':
            'Wrong account. $attemptedRole login requires $attemptedRole credentials.',
      };
    }

    // ── Step 3: Authenticate with Firebase ──
    try {
      await _auth.signInWithEmailAndPassword(
        email: normalizedEmail,
        password: password,
      );
      return {
        'success': true,
        'role': assignedRole,
        'email': normalizedEmail,
      };
    } on FirebaseAuthException catch (e) {
      // NOTE: Auto-creation was removed for security. 
      // Users must be created manually in the Firebase Console.
      return {
        'success': false,
        'error': e.code == 'user-not-found' 
          ? 'Account not found in Firebase. Please contact your administrator.'
          : e.message ?? 'Authentication failed.',
      };
    } catch (e) {
      return {'success': false, 'error': 'Unexpected error: $e'};
    }
  }

  Future<void> signOut() async {
    await _auth.signOut();
  }

  String getRoleFromEmail(String email) {
    return _roles[email.toLowerCase()] ?? 'Unknown';
  }

  User? get currentUser => _auth.currentUser;
}