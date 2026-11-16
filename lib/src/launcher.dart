/// What loop_launcher asks of the box: emptying a journey user's home, and
/// starting a path's loop as its loop user.
library;

import 'package:is_airlock_api/is_airlock_api.dart' show PathToken;
import 'package:is_journal/is_journal.dart' show EntryHash;
import 'package:is_shapes/is_shapes.dart' show JourneyPathId;

import 'pool_user.dart';

/// Starts and stops what runs as the pools' users. On the box, each call
/// starts or stops fixed units that polkit lets loop_launcher's user start
/// and stop by name and nothing else: `journey-wipe@journey-<n>`,
/// `program@journey-<n>` (its socket and service), and
/// `agent-loop@loop-<n>`. polkit is given no details of a transient unit,
/// so only named template instances can be granted.
abstract interface class Launcher {
  /// Stops [user]'s program socket and service, then empties its home and
  /// ends every process running as it, in that order, so nothing the
  /// airlock asks for can run while the home is emptied. Throws a
  /// [LaunchFailed] if it couldn't, and then [user] is not handed out.
  Future<void> wipe(JourneyUser user);

  /// Starts [user]'s program socket, which the airlock's program driver
  /// connects to so a path's programs run as [user]; does nothing if it is
  /// running. Throws a [LaunchFailed] if it did not start.
  Future<void> openPrograms(JourneyUser user);

  /// Starts [path]'s loop as [user], with [token] and [root], the
  /// `assigned` entry its chain starts from, or starts it again if it is
  /// running, so that a token and the loop holding it end together. Throws
  /// a [LaunchFailed] if the loop did not start.
  Future<void> start(
    LoopUser user,
    JourneyPathId path,
    EntryHash root,
    PathToken token,
  );
}

/// A [Launcher] call that did not do what it says; [why] says what
/// happened.
final class LaunchFailed implements Exception {
  const LaunchFailed(this.why);

  final String why;

  @override
  String toString() => 'LaunchFailed: $why';
}
