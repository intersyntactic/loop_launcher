import 'dart:convert';
import 'dart:typed_data';

import 'package:is_airlock_api/is_airlock_api.dart' show LoopUser, Suit;
import 'package:is_logbook/service.dart' show Kind;
import 'package:is_shapes/is_shapes.dart' show MissionId, TrajectoryId;

/// The entry that hands [trajectory], in [mission], its [loopUser] and
/// [suit], and roots the trajectory's chain. The logbook takes the chain's
/// later entries only from [loopUser].
final class UsersAssignedToTrajectory {
  const UsersAssignedToTrajectory({
    required this.trajectory,
    required this.mission,
    required this.loopUser,
    required this.suit,
  });

  static final kind = Kind.usersAssignedToTrajectory;

  /// [body] read strictly; null when it is not exactly this entry's body.
  static UsersAssignedToTrajectory? decode(Uint8List body) {
    final Object? json;
    try {
      json = jsonDecode(utf8.decode(body));
    } on FormatException {
      return null;
    }
    if (json
        case {
          'trajectory': final String trajectory,
          'mission': final String mission,
          'loopUser': final String loopUser,
          'suit': final String suit,
        }
        when json.length == 4) {
      return switch ((
        TrajectoryId.parse(trajectory),
        MissionId.parse(mission),
        LoopUser.parse(loopUser),
        Suit.parse(suit),
      )) {
        (final t?, final m?, final l?, final s?) => UsersAssignedToTrajectory(
          trajectory: t,
          mission: m,
          loopUser: l,
          suit: s,
        ),
        _ => null,
      };
    }
    return null;
  }

  final TrajectoryId trajectory;
  final MissionId mission;
  final LoopUser loopUser;
  final Suit suit;

  Uint8List encode() => Uint8List.fromList(
    utf8.encode(
      jsonEncode({
        'trajectory': trajectory.hex,
        'mission': mission.hex,
        'loopUser': loopUser.name,
        'suit': suit.name,
      }),
    ),
  );
}
