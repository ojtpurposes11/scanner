import 'package:firebase_auth/firebase_auth.dart';

class AuthService {
  final FirebaseAuth _auth = FirebaseAuth.instance;

  // Allowed credentials — username (email) → password
  static const Map<String, String> _credentials = {
    'admin@convergent.com': 'conv_admin2026',
    'field@convergent.com': 'conv_field2026',
  };

  // Each email is locked to exactly one role
  static const Map<String, String> _roles = {
    'admin@convergent.com': 'Admin',
    'field@convergent.com': 'Field Collector',
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
      // Sign out any existing session so it can't bleed through
      await _auth.signOut();
      return {'success': false, 'error': 'Invalid username or password.'};
    }

    // ── Step 2: Enforce role lock ──
    // The email must belong to the role the user is trying to log into.
    final assignedRole = _roles[normalizedEmail]!;
    if (attemptedRole != null && assignedRole != attemptedRole) {
      // Sign out any stale Firebase session immediately
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
      // Auto-create the Firebase user if it doesn't exist yet
      if (e.code == 'user-not-found' || e.code == 'invalid-credential') {
        try {
          await _auth.createUserWithEmailAndPassword(
            email: normalizedEmail,
            password: password,
          );
          return {
            'success': true,
            'role': assignedRole,
            'email': normalizedEmail,
          };
        } catch (_) {
          return {
            'success': false,
            'error': 'Could not create account. Check Firebase Auth settings.',
          };
        }
      }
      return {
        'success': false,
        'error': e.message ?? 'Authentication failed. Try again.',
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