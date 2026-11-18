/// Form validation shared by the auth screens.
///
/// These mirror Appwrite's own server-side rules so the user gets an inline
/// message instead of a round-trip and a raw API error.
class Validate {
  const Validate._();

  // Deliberately permissive: the emailed code is the real proof the address
  // works, so an over-strict pattern here only rejects valid addresses.
  static final _email = RegExp(r'^[^@\s]+@[^@\s.]+\.[^@\s]{2,}$');

  static String? name(String? value) {
    final v = (value ?? '').trim();
    if (v.isEmpty) return 'Tell us your name';
    if (v.length < 2) return 'That looks a little short';
    if (v.length > 128) return 'Please use a shorter name';
    return null;
  }

  static String? email(String? value) {
    final v = (value ?? '').trim();
    if (v.isEmpty) return 'Enter your email';
    if (!_email.hasMatch(v)) return 'That does not look like an email';
    return null;
  }

  /// Appwrite requires 8 to 256 characters.
  static String? password(String? value) {
    final v = value ?? '';
    if (v.isEmpty) return 'Choose a password';
    if (v.length < 8) return 'Use at least 8 characters';
    if (v.length > 256) return 'That password is too long';
    return null;
  }

  static String? loginPassword(String? value) {
    final v = value ?? '';
    if (v.isEmpty) return 'Enter your password';
    return null;
  }

  /// Normalises a consumer number the same way the server does: trimmed,
  /// uppercased, with all whitespace removed.
  ///
  /// Both sides must agree character for character. Submitting the raw text
  /// while validating something else would let a value pass here and fail on
  /// the server, or match the bill photo on one side but not the other.
  static String normalizeConsumerNo(String? value) =>
      (value ?? '').trim().toUpperCase().replaceAll(RegExp(r'\s+'), '');

  /// Mirrors the server's `^[A-Z0-9-]{6,20}$` check on the normalised value.
  ///
  /// Only the shape is checked; the OCR match against the bill photo is what
  /// actually verifies the number belongs to this user.
  static String? consumerNo(String? value) {
    final v = normalizeConsumerNo(value);
    if (v.isEmpty) return 'Enter your consumer number';
    if (v.length < 6) return 'That seems too short to be a consumer number';
    if (v.length > 20) return 'Consumer numbers are at most 20 characters';
    if (!RegExp(r'^[A-Z0-9-]+$').hasMatch(v)) {
      // Slashes and dots appear on some printed bills but the server rejects
      // them, so say so here rather than failing after a round trip.
      return 'Use only letters, numbers and dashes';
    }
    return null;
  }
}
