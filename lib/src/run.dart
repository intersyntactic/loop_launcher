import 'dart:async';
import 'dart:convert';
import 'dart:math' show min;
import 'dart:typed_data';

import 'package:is_airlock_api/is_airlock_api.dart'
    show JsonObject, WaitingToStart;
import 'package:is_docking_station_api/is_docking_station_api.dart'
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
/// A step the machine refuses is tried again, through [schedule], after a
/// wait that doubles from 2s to a minute, for as long as the trajectory is
/// live. A try waits its turn behind the logbook's entries.
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
  void Function(Duration after, void Function() then) schedule = _later,
}) async {
  final started = <TrajectoryId, (MissionId, WhatMayLeaveThisMachine)>{};
  final waiting = <TrajectoryId>{};
  // The logbook's items and the tries again, taken one at a time.
  late final StreamController<Future<void> Function()> lane;

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

  /// False when the machine refused a step, so trying again may help.
  Future<bool> bringUp(
    TrajectoryId trajectory,
    MissionId mission,
    WhatMayLeaveThisMachine rules,
  ) async {
    var held = pools.of(trajectory);
    if (held == null) {
      for (final signIn in rules.modelSignInsCallsMayGoOutAs) {
        switch (loopLimits.of(signIn)) {
          case null:
            await wait(trajectory, 'no loop limit is set for $signIn');
            return true;
          case final limit when holdingUsers(signIn) >= limit:
            await wait(trajectory, '$signIn is at its limit of $limit');
            return true;
        }
      }
      final users = pools.freeUsers(trajectory, mission);
      if (users == null) {
        await wait(trajectory, 'no loop user or suit free');
        return true;
      }
      try {
        await machine.wipeSuit(users.suit);
      } on LaunchFailed catch (e) {
        say('${users.suit}: not handed out: ${e.why}');
        return false;
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
      return false;
    }
    try {
      await machine.startTrajectoryLoop(users.loopUser);
    } on LaunchFailed catch (e) {
      say('${trajectory.hex}: its loop did not start: ${e.why}');
      return false;
    }
    return true;
  }

  final tries = <TrajectoryId, int>{};
  final tryPending = <TrajectoryId>{};

  // Brings [trajectory] up again once the wait is over and the lane reaches
  // it, unless a try is already pending or the trajectory has gone.
  void retry(TrajectoryId trajectory) {
    if (!tryPending.add(trajectory)) return;
    final tried = tries[trajectory] = (tries[trajectory] ?? 0) + 1;
    final after = Duration(seconds: min(1 << min(tried, 6), 60));
    say('${trajectory.hex}: trying again in ${after.inSeconds}s');
    schedule(after, () {
      if (lane.isClosed) return;
      lane.add(() async {
        tryPending.remove(trajectory);
        final done = switch (started[trajectory]) {
          (final mission, final rules) => await bringUp(
            trajectory,
            mission,
            rules,
          ),
          null => true,
        };
        if (done) {
          tries.remove(trajectory);
        } else {
          retry(trajectory);
        }
      });
    });
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
      if (pools.of(trajectory) == null &&
          !await bringUp(trajectory, mission, rules)) {
        retry(trajectory);
      }
    }
  }

  var caughtUp = false;
  Future<void> take(Subscribed item) async {
    switch (item) {
      case Entry(:final kind, :final id, :final body)
          when kind == UsersAssignedToTrajectory.kind:
        final users =
            UsersAssignedToTrajectory.decode(body) ??
            (throw EntryUnreadable(id, 'not users assigned to a trajectory'));
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
          throw EntryUnreadable(id, e.message);
        }
      case Entry(:final kind) when !DecisionEntryKind.all.contains(kind):
        if (router.route(item) case final trajectory? when caughtUp) {
          deliver(trajectory, item);
        }
      case Entry(:final kind, :final id, recorded: final bytes, :final body):
        switch (_reading(id, () => decodeDecision(kind, body)) ??
            (throw EntryUnreadable(id, 'not a ${kind.name} decision'))) {
          case EventAdmittedToMission(
            placement: StartsTrajectory(mission: final placement),
            :final rules,
          ):
            final trajectory = TrajectoryId.of(bytes);
            final mission = switch (placement) {
              InMission(:final mission) => mission,
              StartsMission() => MissionId.of(bytes),
            };
            final typed = _reading(
              id,
              () => FlightRules.fromJson(
                rules ??
                    (throw EntryUnreadable(
                      id,
                      'starts a trajectory with no rules',
                    )),
              ),
            ).whatMayLeaveThisMachine;
            started[trajectory] = (mission, typed);
            router.started(trajectory, item);
            if (caughtUp && !await bringUp(trajectory, mission, typed)) {
              retry(trajectory);
            }
          case EventAdmittedToMission(
            placement: OnTrajectory(:final trajectory),
          ):
            if (router.placed(trajectory, item) && caughtUp) {
              deliver(trajectory, item);
            }
          case MissionEnded(:final mission):
            await release((_, m) => m == mission, stop: caughtUp);
          case TrajectoryClosed(:final trajectory):
            await release((t, _) => t == trajectory, stop: caughtUp);
          // Neither starts a trajectory nor joins one, so no loop is handed it.
          case EventAdmittedToMission(placement: IntoMission()):
          case EventNotAdmittedToMission():
            break;
        }
      case CaughtUp():
        caughtUp = true;
        // A trajectory closed while loop_launcher was down was freed in the
        // replay without its loop stopped, so nothing unheld may run on.
        final (:loopUsers, :suits) = pools.unheld;
        for (final user in loopUsers) {
          try {
            await machine.stopTrajectoryLoop(user);
          } on LaunchFailed catch (e) {
            say('$user: did not stop: ${e.why}');
          }
        }
        for (final suit in suits) {
          try {
            await machine.closeSuitPrograms(suit);
          } on LaunchFailed catch (e) {
            say('$suit: programs did not close: ${e.why}');
          }
        }
        for (final MapEntry(key: trajectory, value: (mission, rules))
            in started.entries.toList()) {
          if (!await bringUp(trajectory, mission, rules)) retry(trajectory);
        }
    }
  }

  late final StreamSubscription<Subscribed> logbook;
  lane = StreamController(
    onListen: () => logbook = subscribe().listen(
      (item) => lane.add(() => take(item)),
      onError: lane.addError,
      onDone: lane.close,
    ),
    onPause: () => logbook.pause(),
    onResume: () => logbook.resume(),
    onCancel: () => logbook.cancel(),
  );
  await for (final work in lane.stream) {
    await work();
  }
}

void _later(Duration after, void Function() then) => Timer(after, then);

/// An entry loop_launcher cannot read, such as one written under rules
/// this version no longer reads. Reading the logbook again meets it again.
final class EntryUnreadable implements Exception {
  const EntryUnreadable(this.entry, this.why);

  final ObjectId entry;
  final String why;

  @override
  String toString() => 'cannot read ${entry.hex}: $why';
}

/// [read]'s value, with a [FormatException] it throws as [EntryUnreadable].
T _reading<T>(ObjectId entry, T Function() read) {
  try {
    return read();
  } on FormatException catch (e) {
    throw EntryUnreadable(entry, e.message);
  }
}
