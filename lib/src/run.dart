/// Running loop_launcher: subscribing to the record, bringing up each
/// journey path the docking station starts, and handing each path's loop
/// its own entries.
library;

import 'dart:typed_data';

import 'package:checked_json/checked_json.dart' show JsonObject;
import 'package:is_docking_station/is_docking_station.dart'
    show
        EventAdmitted,
        DecisionEntryKind,
        JourneyEnded,
        InJourney,
        StartsJourney,
        StartsJourneyPath,
        decodeDecision;
import 'package:is_journal/is_journal.dart' show EntryHash;
import 'package:is_journal/service.dart' show Kind;
import 'package:is_journal_client/is_journal_client.dart'
    show CaughtUp, Entry, Subscribed;
import 'package:is_shapes/is_shapes.dart' show JourneyId, JourneyPathId;

import 'assigned.dart';
import 'launcher.dart';
import 'path_router.dart';
import 'pools.dart';

/// Runs loop_launcher until [subscribe]'s stream ends, which it never
/// should: the caller treats a return as the record going away.
///
/// It subscribes to every entry in the record from its start: the docking
/// station's `admitted` and `ended` entries, its own `assigned` ones, and
/// every other entry, which [router] sorts by path. Once [subscribe] has
/// caught up, it brings up every live path, in the record's
/// order, and then each one as it starts. Bringing up a path, on this start
/// or the next, is the same steps, each skipped when already done:
///
/// 1. hand it a loop user and a suit from [pools], wiping the suit with
///    [launcher] first, and record that with [send] as an `assigned`
///    entry, which roots the path's chain (Nick, 16 Nov: "amend"): the
///    journal takes the chain's entries only from the loop user it names,
///    and refuses a second one for the path;
/// 2. open its suit's programs with [launcher], contained or open as
///    [suitKindOf] reads from its rules;
/// 3. start its loop with [launcher], under the rules the entry that started
///    it recorded, so a restart starts it under the same ones.
///
/// It tells the airlock nothing (Nick, 16 Nov: "loop_launcher shouldn't be
/// using the airlock to record, it should just record itself"): the airlock
/// reads each path's rules and users from the record. A path whose loop
/// doesn't start is said with [say] and left until the next start; a pool
/// with no user free stops nothing else.
///
/// Every entry on a live path's chain, or answering a proposal that is, is
/// kept in [router]'s history for that path, and once caught up is also
/// handed to [deliver]: a loop is handed its path's history when it
/// connects, then each entry [deliver] is given for its path. Before
/// caught up no loop is running, so the history is all there is.
///
/// A journey's `ended` stops its loops and closes its programs, once caught
/// up, then frees its users and drops its paths, from [pools] and [router],
/// so no later start brings them up again. One ended before this start has nothing of its own
/// running unless loop_launcher stopped between the two; a loop left so is
/// stopped when its loop user is started for another path, and the journal
/// refuses its writes meanwhile, its chain being closed.
Future<void> runLoopLauncher({
  required Stream<Subscribed> Function() subscribe,
  required Future<EntryHash> Function(
    Kind kind,
    EntryHash? previous,
    Uint8List body,
  )
  send,
  required Pools pools,
  required PathRouter router,
  required void Function(JourneyPathId path, Entry entry) deliver,
  required SuitKind Function(JsonObject rules) suitKindOf,
  required Launcher launcher,
  required void Function(String line) say,
}) async {
  // Every live path started, with its journey and the rules it started
  // under, in the record's order.
  final started = <JourneyPathId, (JourneyId, JsonObject)>{};

  Future<void> bringUp(
    JourneyPathId path,
    JourneyId journey,
    JsonObject rules,
  ) async {
    var held = pools.of(path);
    if (held == null) {
      switch (pools.handout(path, journey)) {
        case Exhausted(:final why):
          say('${path.hex}: not brought up: $why');
          return;
        case Free(assigned: final free):
          try {
            await launcher.wipe(free.suit);
          } on LaunchFailed catch (e) {
            say('${free.suit}: not handed out: ${e.why}');
            return;
          }
          final root = await send(Assigned.kind, null, free.encode());
          pools.take(free, root);
          held = Held(free, root);
      }
    }
    final Held(:assigned, :root) = held;
    try {
      await launcher.openPrograms(assigned.suit, suitKindOf(rules));
    } on LaunchFailed catch (e) {
      say('${path.hex}: its programs cannot run: ${e.why}');
      return;
    }
    try {
      await launcher.start(assigned.loopUser, path, root, rules);
    } on LaunchFailed catch (e) {
      say('${path.hex}: its loop did not start: ${e.why}');
    }
  }

  Future<void> end(JourneyId journey, {required bool stop}) async {
    final paths = [
      for (final held in pools.live)
        if (held.assigned.journey == journey) held.assigned,
    ];
    if (stop) {
      for (final assigned in paths) {
        try {
          await launcher.stop(assigned.loopUser);
        } on LaunchFailed catch (e) {
          say('${assigned.loopUser}: did not stop: ${e.why}');
        }
        try {
          await launcher.closePrograms(assigned.suit);
        } on LaunchFailed catch (e) {
          say('${assigned.suit}: programs did not close: ${e.why}');
        }
      }
    }
    for (final assigned in paths) {
      router.ended(assigned.journeyPath);
    }
    pools.ended(journey);
    started.removeWhere((_, s) => s.$1 == journey);
  }

  var caughtUp = false;
  await for (final item in subscribe()) {
    switch (item) {
      case Entry(:final kind, :final hash, :final body)
          when kind == Assigned.kind:
        final assigned =
            Assigned.decode(body) ??
            (throw StateError('cannot read the assigned ${hash.hex}'));
        pools.take(assigned, hash);
        router.rooted(assigned.journeyPath, hash);
      // Only `get` returns an entry recorded without a header; one here
      // means the subscription is not what was asked for.
      case Entry(kind: null, :final hash):
        throw StateError('${hash.hex} has no kind');
      case Entry(:final kind?) when !DecisionEntryKind.all.contains(kind):
        if (router.route(item) case final path? when caughtUp) {
          deliver(path, item);
        }
      case Entry(
        kind: final kind?,
        :final hash,
        recorded: final bytes,
        :final body,
      ):
        // Our own wire, read strictly: an entry this pin of the docking
        // station can't read means the two have drifted, and skipping it
        // would leave its path never brought up, unsaid.
        switch (decodeDecision(kind, body) ??
            (throw StateError('cannot read the ${kind.name} ${hash.hex}'))) {
          case EventAdmitted(
            placement: StartsJourneyPath(journey: final placement),
            :final rules,
          ):
            final path = JourneyPathId.of(bytes);
            final journey = switch (placement) {
              InJourney(:final journey) => journey,
              StartsJourney() => JourneyId.of(bytes),
            };
            final pathRules =
                rules ??
                (throw StateError('${hash.hex} starts a path with no rules'));
            started[path] = (journey, pathRules);
            if (caughtUp) await bringUp(path, journey, pathRules);
          case JourneyEnded(:final journey):
            await end(journey, stop: caughtUp);
          case _:
            break;
        }
      case CaughtUp():
        caughtUp = true;
        for (final MapEntry(key: path, value: (journey, rules))
            in started.entries.toList()) {
          await bringUp(path, journey, rules);
        }
    }
  }
}
