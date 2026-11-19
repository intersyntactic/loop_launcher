import 'package:is_effects/is_effects.dart' show ModelSignInName;

/// How many trajectories holding loop users may at once be allowed to make
/// model calls as each sign-in.
final class LoopLimitPerModelSignIn {
  LoopLimitPerModelSignIn._(this._limits);

  /// [raw] as comma-separated `sign-in:count` pairs, such as
  /// `cam-chatgpt:4,nick-claude-team:4`; null when a pair is not exactly
  /// that, with a count of plain digits, or a sign-in is named twice.
  static LoopLimitPerModelSignIn? parse(String raw) {
    final limits = <ModelSignInName, int>{};
    for (final pair in raw.split(',')) {
      if (pair.split(':') case [final name, final count]) {
        final signIn = ModelSignInName.parse(name);
        final limit = _digits.hasMatch(count) ? int.tryParse(count) : null;
        if (signIn == null || limit == null || limits.containsKey(signIn)) {
          return null;
        }
        limits[signIn] = limit;
      } else {
        return null;
      }
    }
    return LoopLimitPerModelSignIn._(Map.unmodifiable(limits));
  }

  final Map<ModelSignInName, int> _limits;

  /// The limit for [signIn]; null when none is set.
  int? of(ModelSignInName signIn) => _limits[signIn];
}

final _digits = RegExp(r'^[0-9]+$');
