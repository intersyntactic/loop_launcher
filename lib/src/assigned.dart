/// The `assigned` entry: which users a journey path was handed, so that
/// when a pool user is handed out again, a file's owner, read with the
/// record, still says which journey wrote it.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:is_journal/service.dart' show Kind;
import 'package:is_shapes/is_shapes.dart' show JourneyId, JourneyPathId;

import 'package:is_airlock_api/is_airlock_api.dart' show JourneyUser, LoopUser;

/// [journeyPath], in [journey], was handed [loopUser] to run its loop and
/// [journeyUser] to own its journey's files. Both are held until the
/// journey's `ended` entry: only `ended` says a journey is over (RULINGS).
///
/// The entry, of kind `assigned`, sent only by loop_launcher's OS user,
/// roots the path's chain: the journal takes the chain's later entries only
/// from [loopUser], until `ended`, and refuses a second `assigned` for the
/// path (Nick, 16 Nov: "amend"):
///
///     {"journeyPath": <hex>, "journey": <hex>, "loopUser": "loop-<n>",
///      "journeyUser": "journey-<n>"}
final class Assigned {
  const Assigned({
    required this.journeyPath,
    required this.journey,
    required this.loopUser,
    required this.journeyUser,
  });

  /// The kind of the entry.
  static final kind = Kind.parse('assigned')!;

  /// [body], an `assigned` entry's body, read strictly: our own wire. Null
  /// when it is not one.
  static Assigned? decode(Uint8List body) {
    final Object? json;
    try {
      json = jsonDecode(utf8.decode(body));
    } on FormatException {
      return null;
    }
    if (json
        case {
          'journeyPath': final String path,
          'journey': final String journey,
          'loopUser': final String loopUser,
          'journeyUser': final String journeyUser,
        }
        when json.length == 4) {
      return switch ((
        JourneyPathId.parse(path),
        JourneyId.parse(journey),
        LoopUser.parse(loopUser),
        JourneyUser.parse(journeyUser),
      )) {
        (final p?, final j?, final l?, final u?) => Assigned(
          journeyPath: p,
          journey: j,
          loopUser: l,
          journeyUser: u,
        ),
        _ => null,
      };
    }
    return null;
  }

  final JourneyPathId journeyPath;
  final JourneyId journey;
  final LoopUser loopUser;
  final JourneyUser journeyUser;

  /// The entry's body.
  Uint8List encode() => Uint8List.fromList(
    utf8.encode(
      jsonEncode({
        'journeyPath': journeyPath.hex,
        'journey': journey.hex,
        'loopUser': loopUser.name,
        'journeyUser': journeyUser.name,
      }),
    ),
  );
}
