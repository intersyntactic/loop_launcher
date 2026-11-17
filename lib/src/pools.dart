import 'dart:collection';

import 'package:is_airlock_api/is_airlock_api.dart' show LoopUser, Suit;
import 'package:is_logbook/is_logbook.dart' show ObjectId;
import 'package:is_shapes/is_shapes.dart' show MissionId, TrajectoryId;

import 'users_assigned_to_trajectory.dart';

/// The loop users and suits, and which trajectory holds which. Rebuilt from
/// the logbook on every start.
final class Pools {
  Pools({required Iterable<LoopUser> loopUsers, required Iterable<Suit> suits})
    : _freeLoops = SplayTreeSet.of(loopUsers, (a, b) => a.n.compareTo(b.n)),
      _freeSuits = SplayTreeSet.of(suits, (a, b) => a.n.compareTo(b.n));

  final SplayTreeSet<LoopUser> _freeLoops;
  final SplayTreeSet<Suit> _freeSuits;
  final _held = <TrajectoryId, (UsersAssignedToTrajectory, ObjectId)>{};

  /// [trajectory]'s users and its chain root, if it has been handed any.
  (UsersAssignedToTrajectory, ObjectId)? of(TrajectoryId trajectory) =>
      _held[trajectory];

  Iterable<(UsersAssignedToTrajectory, ObjectId)> get live => _held.values;

  /// The trajectory [user] runs, if any.
  TrajectoryId? heldBy(LoopUser user) {
    for (final (users, _) in _held.values) {
      if (users.loopUser == user) return users.trajectory;
    }
    return null;
  }

  /// Takes [users], recorded at [root].
  void take(UsersAssignedToTrajectory users, ObjectId root) {
    _freeLoops.remove(users.loopUser);
    _freeSuits.remove(users.suit);
    _held[users.trajectory] = (users, root);
  }

  /// A free loop user and suit for [trajectory], taking neither; null when
  /// none is free. Both pools are the same size and each trajectory takes
  /// one of each, so they run out together.
  UsersAssignedToTrajectory? freeUsers(
    TrajectoryId trajectory,
    MissionId mission,
  ) => switch ((_freeLoops.firstOrNull, _freeSuits.firstOrNull)) {
    (final loop?, final suit?) => UsersAssignedToTrajectory(
      trajectory: trajectory,
      mission: mission,
      loopUser: loop,
      suit: suit,
    ),
    _ => null,
  };

  /// Frees the users of every trajectory in [mission].
  void ended(MissionId mission) {
    _held.removeWhere((_, held) {
      final (users, _) = held;
      if (users.mission != mission) return false;
      _freeLoops.add(users.loopUser);
      _freeSuits.add(users.suit);
      return true;
    });
  }
}
