/// Running loop_launcher: subscribing to the record, and bringing up each
/// journey path the docking station starts.
library;

import 'dart:typed_data';

import 'package:agent_loop/agent_loop.dart'
    show CaughtUp, FollowItem, JournalEntryFrame;
import 'package:is_airlock_api/is_airlock_api.dart'
    show PathStarted, PathStartedAnswer, Ready, Rejected;
import 'package:is_docking_station/is_docking_station.dart'
    show
        Admitted,
        DecisionKind,
        InJourney,
        StartsJourney,
        StartsJourneyPath,
        decodeDecision;
import 'package:is_journal/is_journal.dart' show EntryHash;
import 'package:is_journal/service.dart' show Kind;
import 'package:is_shapes/is_shapes.dart' show JourneyId, JourneyPathId;

import 'assigned.dart';
import 'launcher.dart';
import 'pools.dart';

/// Runs loop_launcher until [subscribe]'s stream ends, which it never
/// should: the caller treats a return as the record going away.
///
/// It subscribes to the record from its start for the docking station's
/// `admitted` entries and its own `assigned` ones. Once [subscribe] has
/// caught up, it
/// brings up every path started, in the record's order, and then each one
/// as it starts. Bringing up a path, on this start or the next, is the same
/// steps, each skipped when already done:
///
/// 1. hand it users from [pools], wiping a journey user new to its journey
///    with [launcher] first, and record that with [send] as an `assigned`
///    entry, which roots the path's chain (Nick, 16 Nov: "amend"): the
///    journal takes the chain's entries only from the loop user it names,
///    and refuses a second one for the path;
/// 2. open its journey user's programs with [launcher];
/// 3. tell the airlock it started, with [pathStarted], under [rulesOf] it;
/// 4. on [Ready], start its loop with [launcher], with the token.
///
/// So after a restart, of loop_launcher or the airlock, each live path is
/// told again and its loop started again with its new token. A path the
/// airlock rejects, or whose loop doesn't start, is said with [say] and left
/// until the next start; a pool with no user free stops nothing else.
///
/// Not yet here: a journey's end. Nothing in the record says which entry
/// ends a journey, so [Pools.ended] is never called and a pool user, once
/// handed out, is held until it does.
Future<void> runLoopLauncher({
  required Stream<FollowItem> Function(Set<Kind> kinds) subscribe,
  required Future<EntryHash> Function(
    Kind kind,
    EntryHash? follows,
    Uint8List body,
  )
  send,
  required Future<PathStartedAnswer> Function(PathStarted message) pathStarted,
  required Object? Function(JourneyPathId path) rulesOf,
  required Pools pools,
  required Launcher launcher,
  required void Function(String line) say,
}) async {
  // Every path started, with its journey, in the record's order.
  final started = <JourneyPathId, JourneyId>{};

  Future<void> bringUp(JourneyPathId path, JourneyId journey) async {
    var held = pools.of(path);
    if (held == null) {
      switch (pools.handout(path, journey)) {
        case Exhausted(:final why):
          say('${path.hex}: not brought up: $why');
          return;
        case Free(assigned: final free, :final wipeFirst):
          if (wipeFirst) {
            try {
              await launcher.wipe(free.journeyUser);
            } on LaunchFailed catch (e) {
              say('${free.journeyUser}: not handed out: ${e.why}');
              return;
            }
          }
          final root = await send(Assigned.kind, null, free.encode());
          pools.take(free, root);
          held = Held(free, root);
      }
    }
    final Held(:assigned, :root) = held;
    try {
      await launcher.openPrograms(assigned.journeyUser);
    } on LaunchFailed catch (e) {
      say('${path.hex}: its programs cannot run: ${e.why}');
      return;
    }
    final answer = await pathStarted(PathStarted(path, rules: rulesOf(path)));
    switch (answer) {
      case Rejected(:final why):
        say('${path.hex}: the airlock rejected it: $why');
      case Ready(:final token):
        try {
          await launcher.start(assigned.loopUser, path, root, token);
        } on LaunchFailed catch (e) {
          say('${path.hex}: its loop did not start: ${e.why}');
        }
    }
  }

  var caughtUp = false;
  await for (final item in subscribe({DecisionKind.admitted, Assigned.kind})) {
    switch (item) {
      case JournalEntryFrame(:final kind, :final hash, :final body)
          when kind == Assigned.kind:
        final assigned =
            Assigned.decode(body) ??
            (throw StateError('cannot read the assigned ${hash.hex}'));
        pools.take(assigned, hash);
      case JournalEntryFrame(:final kind, :final bytes, :final body):
        final decision = decodeDecision(kind, body);
        if (decision case Admitted(
          placement: StartsJourneyPath(journey: final placement),
        )) {
          final path = JourneyPathId.of(bytes);
          final journey = switch (placement) {
            InJourney(:final journey) => journey,
            StartsJourney() => JourneyId.of(bytes),
          };
          started[path] = journey;
          if (caughtUp) await bringUp(path, journey);
        }
      case CaughtUp():
        caughtUp = true;
        for (final MapEntry(key: path, value: journey) in started.entries) {
          await bringUp(path, journey);
        }
    }
  }
}
