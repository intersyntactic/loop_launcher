import 'dart:io';

import 'package:is_airlock_api/is_airlock_api.dart' show LoopUser, Suit;
import 'package:is_flight_rules/is_flight_rules.dart' show ProgramsNetwork;

/// What loop_launcher asks of the machine for a trajectory. Each call throws
/// [LaunchFailed] when it did not do what it says.
abstract interface class StartsAndStopsTrajectoryProcesses {
  /// Stops [suit]'s programs, then empties its home and ends every process
  /// running as it.
  Future<void> wipeSuit(Suit suit);

  Future<void> openSuitPrograms(Suit suit, ProgramsNetwork network);

  Future<void> closeSuitPrograms(Suit suit);

  /// Starts the loop that runs as [user]; it finds its trajectory in the
  /// logbook. Does nothing if it is running.
  Future<void> startTrajectoryLoop(LoopUser user);

  Future<void> stopTrajectoryLoop(LoopUser user);
}

final class LaunchFailed implements Exception {
  const LaunchFailed(this.why);

  final String why;

  @override
  String toString() => 'LaunchFailed: $why';
}

/// The machine's template units, started and stopped by name with systemctl;
/// polkit lets loop_launcher's user touch these instances and nothing else.
final class SystemdUnits implements StartsAndStopsTrajectoryProcesses {
  SystemdUnits({
    Future<ProcessResult> Function(List<String> arguments)? systemctl,
  }) : _systemctl =
           systemctl ??
           ((arguments) =>
               Process.run('systemctl', ['--no-ask-password', ...arguments]));

  final Future<ProcessResult> Function(List<String> arguments) _systemctl;

  Future<void> _run(List<String> arguments) async {
    final result = await _systemctl(arguments);
    if (result.exitCode != 0) {
      throw LaunchFailed(
        'systemctl ${arguments.join(' ')}: exit ${result.exitCode}: '
        '${'${result.stderr}'.trim()}',
      );
    }
  }

  static String _unit(ProgramsNetwork network, Suit suit) => switch (network) {
    ProgramsNetwork.noNetworkOfTheirOwn => 'program-contained@$suit',
    ProgramsNetwork.sharesThisMachinesNetwork => 'program-open@$suit',
  };

  @override
  Future<void> wipeSuit(Suit suit) async {
    await closeSuitPrograms(suit);
    await _run(['start', 'suit-wipe@$suit']);
  }

  @override
  Future<void> openSuitPrograms(Suit suit, ProgramsNetwork network) =>
      _run(['start', _unit(network, suit)]);

  @override
  Future<void> closeSuitPrograms(Suit suit) => _run([
    'stop',
    for (final network in ProgramsNetwork.values) _unit(network, suit),
  ]);

  @override
  Future<void> startTrajectoryLoop(LoopUser user) =>
      _run(['start', 'agent-loop@$user']);

  @override
  Future<void> stopTrajectoryLoop(LoopUser user) =>
      _run(['stop', 'agent-loop@$user']);
}
