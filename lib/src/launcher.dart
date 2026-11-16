/// What loop_launcher asks of the box: emptying a suit's home, and starting
/// a path's loop as its loop user.
library;

import 'package:checked_json/checked_json.dart' show JsonObject;
import 'package:is_airlock_api/is_airlock_api.dart' show LoopUser, Suit;
import 'package:is_journal/is_journal.dart' show EntryHash;
import 'package:is_shapes/is_shapes.dart' show JourneyPathId;

/// Starts and stops what runs as the pools' users. On the box, each call is
/// `systemctl --no-ask-password start|stop` of a fixed unit that polkit lets
/// loop_launcher's user start or stop by name and nothing else
/// (https://github.com/enspyrco/infra/pull/389): `program-contained@suit-<n>`,
/// `program-open@suit-<n>`, `suit-wipe@suit-<n>` (start only), and
/// `agent-loop@loop-<n>`. polkit is given no details of a transient unit,
/// so only named template instances can be granted, and no restart is.
/// Each unit is Restart=no: loop_launcher is the only thing that starts
/// one, and a start the box refuses stays refused.
abstract interface class Launcher {
  /// Stops both of [suit]'s program units, then starts
  /// `suit-wipe@<suit>`, which returns once its home is empty and every
  /// process running as it has ended, so no program the airlock decides on
  /// can run while the home is emptied. The box refuses a wipe while a
  /// program unit is up. Throws a [LaunchFailed] if it couldn't, and then
  /// [suit] is not handed out.
  Future<void> wipe(Suit suit);

  /// Starts [suit]'s program unit of [kind], which the airlock's program
  /// driver connects to so a path's programs run as [suit]; does nothing
  /// if it is running. The box refuses one kind while the other is up.
  /// Throws a [LaunchFailed] if it did not start.
  Future<void> openPrograms(Suit suit, SuitKind kind);

  /// Stops both of [suit]'s program units, when its journey has ended;
  /// stopping one that isn't running does nothing. Throws a [LaunchFailed]
  /// if they did not stop.
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

/// How sealed a path's suit is, chosen per handout by its rules (Nick,
/// 16 Nov: a contained path's suit is sealed, an open path's has the visor
/// up; the suit is the same kind of thing either way).
enum SuitKind {
  /// `program-contained@`: its programs get a network of their own.
  contained,

  /// `program-open@`: its programs share the box's network.
  open,
}

/// A [Launcher] call that did not do what it says; [why] says what
/// happened.
final class LaunchFailed implements Exception {
  const LaunchFailed(this.why);

  final String why;

  @override
  String toString() => 'LaunchFailed: $why';
}
