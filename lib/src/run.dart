import 'dart:convert';
import 'dart:typed_data';

import 'package:is_airlock_api/is_airlock_api.dart'
    show JsonObject, WaitingToStart;
import 'package:is_admission_vocabulary/is_admission_vocabulary.dart'
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
        TrajectoryClosed,
        decodeDecision;
import 'package:is_effects/is_effects.dart' show ModelSignInName;
import 'package:is_flight_rules/is_flight_rules.dart'
    show FlightRules, WhatMayLeaveThisMachine;
import 'package:is_logbook_client/is_logbook_client.dart'
    show CaughtUp, Entry, Kind, ObjectId, Subscribed;
import 'package:is_shapes/is_shapes.dart' show MissionId, TrajectoryId;

import 'loop_limit_per_model_sign_in.dart';
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
/// free, or when its rules let its calls go out as a sign-in that
/// [loopLimits] sets no limit for, or one whose limit is reached by
/// trajectories that have users and whose rules allow it. Allowed, not
/// chosen: a trajectory may switch to any sign-in its rules allow. A
/// mission's end stops its loops, and a trajectory's close stops its own;
/// either frees the users and brings up whoever waits, oldest first.
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
  required LoopLimitPerModelSignIn loopLimits,
  required StartsAndStopsTrajectoryProcesses machine,
  required void Function(String line) say,
}) async {
  final started = <TrajectoryId, (MissionId, WhatMayLeaveThisMachine)>{};
  final waiting = <TrajectoryId>{};

  int holdingUsers(ModelSignInName signIn) => started.entries
      .where((s) => s.value.$2.allowsModelCall(signIn))
      .where((s) => pools.of(s.key) != null)
      .length;

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
      for (final signIn in rules.modelSignInsCallsMayGoOutAs) {
        switch (loopLimits.of(signIn)) {
          case null:
            return wait(trajectory, 'no loop limit is set for $signIn');
          case final limit when holdingUsers(signIn) >= limit:
            return wait(trajectory, '$signIn is at its limit of $limit');
        }
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

  /// Stops and frees every trajectory [ending] picks, forgets it, and once
  /// caught up ([stop]) brings up whoever waits, oldest first.
  Future<void> release(
    bool Function(TrajectoryId trajectory, MissionId mission) ending, {
    required bool stop,
  }) async {
    final freed = [
      for (final (users, _) in pools.live)
        if (ending(users.trajectory, users.mission)) users,
    ];
    if (stop) {
      for (final users in freed) {
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
    for (final users in freed) {
      router.ended(users.trajectory);
      pools.free(users.trajectory);
    }
    final gone = [
      for (final MapEntry(key: trajectory, value: (mission, _))
          in started.entries)
        if (ending(trajectory, mission)) trajectory,
    ];
    for (final trajectory in gone) {
      router.ended(trajectory);
      waiting.remove(trajectory);
      started.remove(trajectory);
    }
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
            WaitingToStart.fromJson(JsonObject.decode(utf8.decode(body)))
                .trajectory,
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
            final typed = FlightRules.fromJson(
              rules ??
                  (throw StateError(
                    '${id.hex} starts a trajectory with '
                    'no rules',
                  )),
            ).whatMayLeaveThisMachine;
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
            await release((_, m) => m == mission, stop: caughtUp);
          case TrajectoryClosed(:final trajectory):
            await release((t, _) => t == trajectory, stop: caughtUp);
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
