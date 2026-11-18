import 'package:appwrite/appwrite.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../config/env.dart';

/// Single Appwrite client for the whole app.
///
/// Only the project ID and endpoint ship in the APK — both are public by
/// design. Every credit-minting write goes through an Appwrite Function that
/// holds the API key server-side.
class Appwrite {
  Appwrite() {
    client = Client()
        .setEndpoint(Env.endpoint)
        .setProject(Env.projectId);

    account = Account(client);
    databases = Databases(client);
    storage = Storage(client);
    functions = Functions(client);
    realtime = Realtime(client);
  }

  late final Client client;
  late final Account account;
  late final Databases databases;
  late final Storage storage;
  late final Functions functions;
  late final Realtime realtime;
}

final appwriteProvider = Provider<Appwrite>((ref) => Appwrite());

final accountProvider = Provider<Account>(
  (ref) => ref.watch(appwriteProvider).account,
);

final databasesProvider = Provider<Databases>(
  (ref) => ref.watch(appwriteProvider).databases,
);

final storageProvider = Provider<Storage>(
  (ref) => ref.watch(appwriteProvider).storage,
);

final functionsProvider = Provider<Functions>(
  (ref) => ref.watch(appwriteProvider).functions,
);

final realtimeProvider = Provider<Realtime>(
  (ref) => ref.watch(appwriteProvider).realtime,
);

/// Turns Appwrite's raw errors into something worth showing a user.
String friendlyError(Object error) {
  if (error is AppwriteException) {
    final message = error.message ?? 'Something went wrong';
    switch (error.type) {
      case 'user_already_exists':
        return 'That email is already registered. Try signing in.';
      case 'user_invalid_credentials':
        return 'Email or password is incorrect.';
      case 'user_invalid_token':
      case 'user_invalid_code':
        return 'That code is invalid or has expired. Request a new one.';
      case 'user_not_found':
        return 'No account found for that email.';
      // Deliberately vague about the wait: the SDK does not surface the
      // remaining window, and the limit is counted per IP, so naming a
      // duration invites a retry that may just be refused again. Nothing here
      // is a credentials problem — the password is not checked once the limit
      // trips, which is why a wrong password and a locked account are
      // indistinguishable at this point.
      case 'general_rate_limit_exceeded':
        return 'Too many sign-in attempts. Wait a few minutes before trying '
            'again — this is not a problem with your password.';
      case 'password_recently_used':
        return 'Choose a password you have not used before.';
      case 'general_argument_invalid':
        return message;
      case 'document_not_found':
        return 'That record no longer exists.';
      case 'storage_file_type_unsupported':
        return 'That file type is not supported. Use a JPG or PNG.';
      case 'storage_invalid_file_size':
        return 'That file is too large. Keep photos under 12 MB.';
    }
    // A 401 with no session at all reads as a scope failure. Reporting that as
    // "sign in again" on the sign-in screen is a dead end for the user.
    if (error.type == 'general_unauthorized_scope') {
      return 'Your session has ended. Sign in to continue.';
    }
    // Unrecognised 401s keep the server's own wording. A guess here is what
    // hides the real fault: every unknown cause looked like a bad password.
    if (error.code == 401) {
      return message.isNotEmpty ? message : 'Please sign in again.';
    }
    if (error.code == 409) return 'That already exists.';
    if (error.code == 429) return 'Too many requests. Slow down a moment.';
    if ((error.code ?? 0) >= 500) {
      return 'Our servers are having a moment. Try again shortly.';
    }
    // The SDK wraps a dropped connection in an AppwriteException with no
    // status code and the raw socket error as its message. That text means
    // nothing to a user, so it must not be shown as-is.
    if (error.code == null && _looksOffline(message)) {
      return 'No internet connection.';
    }
    return message;
  }
  if (_looksOffline(error.toString())) return 'No internet connection.';
  return 'Something went wrong. Please try again.';
}

bool _looksOffline(String text) =>
    text.contains('SocketException') ||
    text.contains('Failed host lookup') ||
    text.contains('ClientException') ||
    text.contains('Connection refused') ||
    text.contains('Connection reset') ||
    text.contains('Network is unreachable');
