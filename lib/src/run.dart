import 'dart:convert';
import 'dart:typed_data';

import 'package:is_airlock_api/is_airlock_api.dart' show WaitingToStart;
import 'package:is_docking_station/is_docking_station.dart'
    show
        DecisionEntryKind,
        EventAdmittedToMission,
        EventNotAdmittedToMission,
        InMission,
        IntoMission,
        MissionEnded,
        OnTrajectory,
        StartsMission,
        StartsTrajectory,
        decodeDecision;
import 'package:is_effects/is_effects.dart' show ModelSignInName;
import 'package:is_flight_rules/is_flight_rules.dart'
    show WhatMayLeaveThisMachine;
import 'package:is_logbook/is_logbook.dart' show ObjectId;
import 'package:is_logbook/service.dart' show Kind;
import 'package:is_logbook_client/is_logbook_client.dart'
    show CaughtUp, Entry, Subscribed;
import 'package:is_shapes/is_shapes.dart' show MissionId, TrajectoryId;

import 'pools.dart';
import 'starts_and_stops_trajectory_processes.dart';
import 'trajectory_router.dart';
import 'users_assigned_to_trajectory.dart';

final waitingToStartKind = Kind.parse(WaitingToStart.kind)!;

/// Runs until [subscribe]'s stream ends. Reads every entry from the
/// logbook's start; once caught up, brings up each live trajectory in the
/// logbook's order, then each new one. Bringing one up hands it a loop user
/// and a wiped suit, records that with [send], opens the suit's programs and
/// starts its loop, skipping whatever is already done.
///
/// A trajectory waits, recorded once as `waiting-to-start`, when no users are
/// free or when [teamLoginLimit] trajectories whose calls may go out as
/// [teamLogin] already have users. A mission's end stops its loops, frees
/// its users and brings up whoever waits, oldest first.
///
/// Entries on a live trajectory's chain are kept in [router]; once caught
/// up, each is also handed to [deliver].
Future<void> runLoopLauncher({
  required Stream<Subscribed> Function() subscribe,
  required Future<ObjectId> Function(
    Kind kind,
    ObjectId? previous,
    Uint8List body,
  )
  send,
  required Pools pools,
  required TrajectoryRouter router,
  required void Function(TrajectoryId trajectory, Entry entry) deliver,
  required ModelSignInName teamLogin,
  required int teamLoginLimit,
  required StartsAndStopsTrajectoryProcesses machine,
  required void Function(String line) say,
}) async {
  final started = <TrajectoryId, (MissionId, WhatMayLeaveThisMachine)>{};
  final waiting = <TrajectoryId>{};

  bool usesTeamLogin(WhatMayLeaveThisMachine rules) =>
      rules.modelSignInsCallsMayGoOutAs.contains(teamLogin);

  Future<void> wait(TrajectoryId trajectory, String why) async {
    if (!waiting.add(trajectory)) return;
    say('${trajectory.hex}: waiting to start: $why');
    await send(
      waitingToStartKind,
      null,
      utf8.encode(jsonEncode(WaitingToStart(trajectory).toJson())),
    );
  }

  Future<void> bringUp(
    TrajectoryId trajectory,
    MissionId mission,
    WhatMayLeaveThisMachine rules,
  ) async {
    var held = pools.of(trajectory);
    if (held == null) {
      if (usesTeamLogin(rules) &&
          started.entries
                  .where((s) => usesTeamLogin(s.value.$2))
                  .where((s) => pools.of(s.key) != null)
                  .length >=
              teamLoginLimit) {
        return wait(trajectory, '$teamLoginLimit trajectories use $teamLogin');
      }
      final users = pools.freeUsers(trajectory, mission);
      if (users == null) return wait(trajectory, 'no loop user or suit free');
      try {
        await machine.wipeSuit(users.suit);
      } on LaunchFailed catch (e) {
        say('${users.suit}: not handed out: ${e.why}');
        return;
      }
      final root = await send(
        UsersAssignedToTrajectory.kind,
        null,
        users.encode(),
      );
      pools.take(users, root);
      held = (users, root);
    }
    final (users, _) = held;
    try {
      await machine.openSuitPrograms(users.suit, rules.programsNetwork);
    } on LaunchFailed catch (e) {
      say('${trajectory.hex}: its programs cannot run: ${e.why}');
      return;
    }
    try {
      await machine.startTrajectoryLoop(users.loopUser);
    } on LaunchFailed catch (e) {
      say('${trajectory.hex}: its loop did not start: ${e.why}');
    }
  }

  Future<void> end(MissionId mission, {required bool stop}) async {
    final ending = [
      for (final (users, _) in pools.live)
        if (users.mission == mission) users,
    ];
    if (stop) {
      for (final users in ending) {
        try {
          await machine.stopTrajectoryLoop(users.loopUser);
        } on LaunchFailed catch (e) {
          say('${users.loopUser}: did not stop: ${e.why}');
        }
        try {
          await machine.closeSuitPrograms(users.suit);
        } on LaunchFailed catch (e) {
          say('${users.suit}: programs did not close: ${e.why}');
        }
      }
    }
    for (final users in ending) {
      router.ended(users.trajectory);
    }
    pools.ended(mission);
    waiting.removeWhere((t) => started[t]?.$1 == mission);
    started.removeWhere((_, s) => s.$1 == mission);
    if (!stop) return;
    for (final MapEntry(key: trajectory, value: (mission, rules))
        in started.entries.toList()) {
      if (pools.of(trajectory) == null) {
        await bringUp(trajectory, mission, rules);
      }
    }
  }

  var caughtUp = false;
  await for (final item in subscribe()) {
    switch (item) {
      case Entry(:final kind, :final id, :final body)
          when kind == UsersAssignedToTrajectory.kind:
        final users =
            UsersAssignedToTrajectory.decode(body) ??
            (throw StateError('cannot read ${id.hex}'));
        pools.take(users, id);
        router.rooted(users.trajectory, item);
        if (caughtUp) deliver(users.trajectory, item);
      case Entry(:final kind, :final id, :final body)
          when kind == waitingToStartKind:
        try {
          waiting.add(
            WaitingToStart.fromJson(jsonDecode(utf8.decode(body))).trajectory,
          );
        } on FormatException catch (e) {
          throw StateError('cannot read ${id.hex}: $e');
        }
      case Entry(:final kind) when !DecisionEntryKind.all.contains(kind):
        if (router.route(item) case final trajectory? when caughtUp) {
          deliver(trajectory, item);
        }
      case Entry(:final kind, :final id, recorded: final bytes, :final body):
        switch (decodeDecision(kind, body) ??
            (throw StateError('cannot read the ${kind.name} ${id.hex}'))) {
          case EventAdmittedToMission(
            placement: StartsTrajectory(mission: final placement),
            :final rules,
            :final event,
          ):
            final trajectory = TrajectoryId.of(bytes);
            final mission = switch (placement) {
              InMission(:final mission) => mission,
              StartsMission() => MissionId.of(bytes),
            };
            final typed = WhatMayLeaveThisMachine.fromJson(
              rules ??
                  (throw StateError(
                    '${id.hex} starts a trajectory with '
                    'no rules',
                  )),
            );
            started[trajectory] = (mission, typed);
            router.started(trajectory, item, event);
            if (caughtUp) await bringUp(trajectory, mission, typed);
          case EventAdmittedToMission(
            placement: OnTrajectory(:final trajectory),
            :final event,
          ):
            if (router.placed(trajectory, item, event) case final added?
                when caughtUp) {
              for (final entry in added) {
                deliver(trajectory, entry);
              }
            }
          case MissionEnded(:final mission):
            await end(mission, stop: caughtUp);
          case EventAdmittedToMission(placement: IntoMission(), :final event):
          case EventNotAdmittedToMission(:final event):
            router.decided(event);
        }
      case CaughtUp():
        caughtUp = true;
        for (final MapEntry(key: trajectory, value: (mission, rules))
            in started.entries.toList()) {
          await bringUp(trajectory, mission, rules);
        }
    }
  }
}
