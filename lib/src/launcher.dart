/// What loop_launcher asks of the box: emptying a suit's home, and starting
/// a path's loop as its loop user.
library;

import 'package:checked_json/checked_json.dart' show JsonObject;
import 'package:is_airlock_api/is_airlock_api.dart' show LoopUser, Suit;
import 'package:is_journal/is_journal.dart' show EntryHash;
import 'package:is_shapes/is_shapes.dart' show JourneyPathId;

/// Starts and stops what runs as the pools' users. On the box, each call
/// starts or stops fixed units that polkit lets loop_launcher's user start
/// and stop by name and nothing else: a suit's wipe and program units
/// (`suit-<n>`'s socket and service, contained or open), and
/// `agent-loop@loop-<n>`. polkit is given no details of a transient unit,
/// so only named template instances can be granted.
abstract interface class Launcher {
  /// Stops [suit]'s program socket and service, then empties its home and
  /// ends every process running as it, in that order, so no program the
  /// airlock decides on can run while the home is emptied. Throws a
  /// [LaunchFailed] if it couldn't, and then [suit] is not handed out.
  Future<void> wipe(Suit suit);

  /// Starts [suit]'s program socket, which the airlock's program driver
  /// connects to so a path's programs run as [suit]; does nothing if it is
  /// running. Throws a [LaunchFailed] if it did not start.
  Future<void> openPrograms(Suit suit);

  /// Stops [suit]'s program socket and service, when its journey has ended;
  /// does nothing if they are not running. Throws a [LaunchFailed] if they
  /// did not stop.
  Future<void> closePrograms(Suit suit);

  /// Stops the loop running as [user], when its journey has ended; does
  /// nothing if none is. Throws a [LaunchFailed] if it did not stop.
  Future<void> stop(LoopUser user);

  /// Starts [path]'s loop as [user], with [root], the `assigned` entry its
  /// chain starts from, and the sign-ins [rules] allow; does nothing if it
  /// is running. Throws a [LaunchFailed] if the loop did not start.
  Future<void> start(
    LoopUser user,
    JourneyPathId path,
    EntryHash root,
    JsonObject rules,
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
