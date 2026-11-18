import 'dart:async';

import 'package:appwrite/appwrite.dart';
import 'package:appwrite/models.dart' as models;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/services/api.dart';
import '../core/services/appwrite.dart';
import '../core/utils/errors.dart';
import '../data/models/profile.dart';
import '../data/repository.dart';

/// Raised by controller actions so form screens can show a message.
///
/// Actions never leave the notifier in a loading or error state: the router
/// reads `state.value` to decide what to show, and both `AsyncValue.error` and
/// `AsyncValue.loading` clear that value. Doing either mid-action would bounce
/// the user to the splash or login screen while their request is in flight.
/// Screens show their own progress indicator instead.
class AuthFailure implements Exception {
  const AuthFailure(this.message);
  final String message;

  @override
  String toString() => message;
}

/// Where the user sits in the sign-in journey. The router keys off this.
sealed class AuthState {
  const AuthState();
}

class AuthSignedOut extends AuthState {
  const AuthSignedOut({this.message});
  final String? message;
}

/// Account exists but the email is not confirmed yet. The userId is retained so
/// the OTP screen can resend and verify without asking for it again.
class AuthAwaitingOtp extends AuthState {
  const AuthAwaitingOtp({
    required this.userId,
    required this.email,
    required this.name,
  });

  final String userId;
  final String email;
  final String name;
}

class AuthSignedIn extends AuthState {
  const AuthSignedIn({required this.user, required this.profile});

  final models.User user;
  final Profile profile;
}

class AuthController extends AsyncNotifier<AuthState> {
  Account get _account => ref.read(accountProvider);

  @override
  Future<AuthState> build() => _restore();

  /// Reuses the persisted Appwrite session if one survives an app restart.
  ///
  /// When the server cannot be reached (offline, timeout, a 5xx) this throws
  /// rather than reporting "signed out". The session stored on the phone is
  /// probably still good, so sending the user to the welcome screen would make
  /// them type their password again for a dead network. The router keeps the
  /// splash screen up while auth has no value, and the splash screen offers a
  /// retry when this fails.
  Future<AuthState> _restore() async {
    final models.User user;
    try {
      user = await _account.get();
    } on AppwriteException catch (e) {
      // 401 just means there is no valid session.
      if (e.code == 401) return const AuthSignedOut();
      if (isTransientError(e)) rethrow;
      return AuthSignedOut(message: friendlyError(e));
    } catch (e) {
      if (isTransientError(e)) rethrow;
      return AuthSignedOut(message: friendlyError(e));
    }

    // Past this point the session is real. If loading the profile fails, the
    // SDK is left holding a live session while the router shows a signed-out
    // UI — and the next sign-in is refused with user_session_already_exists,
    // which no password can get past. Drop the session so the login screen the
    // user is sent to actually works.
    //
    // Except when the failure is only the network: the session is fine, and
    // deleting it would sign the user out because of a weak signal.
    try {
      return await _resolveSignedIn(user);
    } catch (e) {
      if (isTransientError(e)) rethrow;
      await _discardSession();
      return AuthSignedOut(message: friendlyMessage(e));
    }
  }

  /// Clears the stored session without disturbing controller state.
  ///
  /// Used when the app has decided it cannot proceed as this user: leaving the
  /// session behind is what strands them on a login screen that refuses every
  /// attempt.
  Future<void> _discardSession() async {
    try {
      await _account.deleteSession(sessionId: 'current');
    } catch (_) {
      // Already gone server-side, or offline. Nothing more to try.
    }
    ref.read(apiProvider).invalidateJwt();
  }

  /// Receiving an emailed code already proves the address works, so a verified
  /// flag is not required past that point.
  Future<AuthState> _resolveSignedIn(models.User user) async {
    final profile = await _loadOrCreateProfile(user);
    return AuthSignedIn(user: user, profile: profile);
  }

  Future<Profile> _loadOrCreateProfile(models.User user) async {
    final repo = ref.read(repositoryProvider);

    final existing = await repo.profile(user.$id);
    if (existing != null) return existing;

    // First real login: the server mints the profile row and referral code.
    final created = await ref.read(apiProvider).bootstrapProfile(
          name: user.name.isNotEmpty ? user.name : 'Friend',
        );
    final payload = created['profile'];
    if (payload is Map<String, dynamic>) return Profile.fromMap(payload);

    // Bootstrap reported success without echoing the row back; read it.
    final fresh = await repo.profile(user.$id);
    if (fresh == null) {
      throw const AuthFailure('Could not finish setting up your account.');
    }
    return fresh;
  }

  /// Restores a known-good state after a failed action, then reports the error.
  ///
  /// Routed through [friendlyMessage] rather than [friendlyError] so a server
  /// rejection keeps its own wording. `friendlyError` only understands
  /// Appwrite's exceptions and would flatten an [ApiFailure] from the API
  /// function into a generic apology, hiding the actual reason.
  Never _fail(Object error, AuthState fallback) {
    state = AsyncValue.data(fallback);
    throw AuthFailure(friendlyMessage(error));
  }

  /// Step 1: create the account, then email a 6-digit code.
  Future<void> signUp({
    required String name,
    required String email,
    required String password,
  }) async {
    final previous = state.value ?? const AuthSignedOut();
    final trimmedEmail = email.trim();
    final trimmedName = name.trim();
    try {
      final user = await _account.create(
        userId: ID.unique(),
        email: trimmedEmail,
        password: password,
        name: trimmedName,
      );
      await _account.createEmailToken(userId: user.$id, email: trimmedEmail);
      state = AsyncValue.data(
        AuthAwaitingOtp(
          userId: user.$id,
          email: trimmedEmail,
          name: trimmedName,
        ),
      );
    } catch (e) {
      _fail(e, previous);
    }
  }

  /// Step 2: exchange the emailed code for a session.
  Future<void> verifyOtp(String code) async {
    final pending = state.value;
    if (pending is! AuthAwaitingOtp) {
      throw const AuthFailure('Start again to receive a new code.');
    }

    try {
      await _account.createSession(
        userId: pending.userId,
        secret: code.trim(),
      );
      ref.read(apiProvider).invalidateJwt();

      final user = await _account.get();
      state = AsyncValue.data(await _resolveSignedIn(user));
    } catch (e) {
      // Keep the user on the OTP screen so they can retry the code.
      _fail(e, pending);
    }
  }

  Future<void> resendOtp() async {
    final pending = state.value;
    if (pending is! AuthAwaitingOtp) return;
    try {
      await _account.createEmailToken(
        userId: pending.userId,
        email: pending.email,
      );
    } catch (e) {
      throw AuthFailure(friendlyError(e));
    }
  }

  /// Normal password login for returning users.
  Future<void> signIn({
    required String email,
    required String password,
  }) async {
    final previous = state.value ?? const AuthSignedOut();
    try {
      try {
        await _account.createEmailPasswordSession(
          email: email.trim(),
          password: password,
        );
      } on AppwriteException catch (e) {
        // A session this controller already gave up on can still be live in the
        // SDK. Appwrite refuses a second one, and refuses it before checking
        // the password — so the user sees a credentials error for something
        // that has nothing to do with their credentials. Clear it and retry
        // once; a genuinely wrong password still fails on the retry.
        if (e.type != 'user_session_already_exists') rethrow;
        await _discardSession();
        await _account.createEmailPasswordSession(
          email: email.trim(),
          password: password,
        );
      }
      ref.read(apiProvider).invalidateJwt();

      // Deliberately not gated on `user.emailVerification`. Appwrite leaves that
      // flag false after an OTP session is created, so branching to the OTP
      // screen here would trap every returning user in a loop they could never
      // finish. The emailed code is the gate at signup; password login is the
      // "log in normally" path afterwards.
      final user = await _account.get();
      state = AsyncValue.data(await _resolveSignedIn(user));
    } catch (e) {
      _fail(e, previous);
    }
  }

  Future<void> sendPasswordReset(String email) async {
    try {
      await _account.createRecovery(
        email: email.trim(),
        // Appwrite requires a URL. Recovery completes on the hosted page until
        // a deep-link handler ships.
        url: 'https://cloud.appwrite.io/auth/recovery',
      );
    } catch (e) {
      throw AuthFailure(friendlyError(e));
    }
  }

  Future<void> signOut() async {
    try {
      await _account.deleteSession(sessionId: 'current');
    } catch (_) {
      // The session may already be gone server-side; sign out locally anyway.
    }
    ref.read(apiProvider).invalidateJwt();
    state = const AsyncValue.data(AuthSignedOut());
  }

  void abandonOtp() => state = const AsyncValue.data(AuthSignedOut());

  /// Re-reads the profile row after credits or stats change.
  Future<void> refreshProfile() async {
    final current = state.value;
    if (current is! AuthSignedIn) return;
    try {
      final profile = await ref.read(repositoryProvider).profile(current.user.$id);
      if (profile == null) return;
      state = AsyncValue.data(
        AuthSignedIn(user: current.user, profile: profile),
      );
    } catch (_) {
      // A failed refresh must never sign the user out.
    }
  }
}

final authControllerProvider =
    AsyncNotifierProvider<AuthController, AuthState>(
  AuthController.new,
  // No automatic retry: a restore that fails offline should show the splash
  // screen's message and Retry button straight away, not spin for ~40 s while
  // Riverpod backs off and retries on its own.
  retry: (_, _) => null,
);

/// True when an error means "could not reach the server right now" rather
/// than a real answer from it. Such errors are worth retrying and must never
/// be treated as the user being signed out.
///
/// The Appwrite SDK wraps a dropped connection in an [AppwriteException] with
/// no status code, so a missing code is the offline case.
bool isTransientError(Object error) {
  if (error is AppwriteException) {
    final code = error.code;
    return code == null || code == 0 || code == 408 || code == 429 ||
        code >= 500;
  }
  if (error is ApiFailure) return error.code == 'function_error';
  if (error is TimeoutException) return true;
  final text = error.toString();
  return text.contains('SocketException') ||
      text.contains('ClientException') ||
      text.contains('Failed host lookup');
}

/// Convenience reads used across the UI.
final currentProfileProvider = Provider<Profile?>((ref) {
  final state = ref.watch(authControllerProvider).value;
  return state is AuthSignedIn ? state.profile : null;
});

final currentUserIdProvider = Provider<String?>((ref) {
  final state = ref.watch(authControllerProvider).value;
  return state is AuthSignedIn ? state.user.$id : null;
});
