/// Running loop_launcher: subscribing to the record, bringing up each
/// journey path the docking station starts, and handing each path's loop
/// its own entries.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:checked_json/checked_json.dart' show JsonObject;
import 'package:is_airlock_api/is_airlock_api.dart' show WaitingToStart;
import 'package:is_docking_station/is_docking_station.dart'
    show
        EventAdmitted,
        EventDeclined,
        DecisionEntryKind,
        JourneyEnded,
        InJourney,
        IntoJourney,
        StartsJourney,
        StartsJourneyPath,
        UnderJourneyPath,
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

/// The kind of the entry that says a path is waiting to start.
final waitingToStartKind = Kind.parse(WaitingToStart.kind)!;

/// Runs loop_launcher until [subscribe]'s stream ends, which it never
/// should: the caller treats a return as the record going away.
///
/// It subscribes to every entry in the record from its start: the docking
/// station's `admitted` and `ended` entries, its own `assigned` and
/// `waiting-to-start` ones, and every other entry, which [router] sorts by
/// path. Once [subscribe] has caught up, it brings up every live path, in
/// the record's order, and then each one as it starts. Bringing up a path,
/// on this start or the next, is the same steps, each skipped when already
/// done:
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
/// A path waits to start, with no users, when no loop user or suit is
/// free, or when its rules sign in on the Team login ([usesTeamLogin]) and
/// [teamLoginLimit] paths that do already have users (Nick, 17 Nov: K = 4
/// for the demo). It is recorded once as `waiting-to-start`, on a chain of
/// its own, since a path with no `assigned` has no chain yet; its
/// `assigned`, when there is room, ends the wait (Nick, 17 Nov: "type's
/// version"). Why it waits is said with [say], to the operator only. Each
/// journey's `ended` makes room, and the waiting paths are brought up again
/// in the record's order, so the oldest starts first.
///
/// It tells the airlock nothing (Nick, 16 Nov: "loop_launcher shouldn't be
/// using the airlock to record, it should just record itself"): the airlock
/// reads each path's rules and users from the record. A path whose loop
/// doesn't start is said with [say] and left until the next start or the
/// next `ended`.
///
/// Every entry on a live path's chain, or answering a proposal that is, is
/// kept in [router]'s history for that path, and once caught up is also
/// handed to [deliver]: a loop is handed its path's history when it
/// connects, then each entry [deliver] is given for its path. Before
/// caught up no loop is running, so the history is all there is.
///
/// A journey's `ended` stops its loops and closes its programs, once caught
/// up, then frees its users and drops its paths, from [pools] and [router],
/// so no later start brings them up again. One ended before this start has
/// nothing of its own running unless loop_launcher stopped between the two;
/// a loop left so is stopped when its loop user is started for another
/// path, and the journal refuses its writes meanwhile, its chain being
/// closed.
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
  required bool Function(JsonObject rules) usesTeamLogin,
  required int teamLoginLimit,
  required Launcher launcher,
  required void Function(String line) say,
}) async {
  // Every live path started, with its journey and the rules it started
  // under, in the record's order.
  final started = <JourneyPathId, (JourneyId, JsonObject)>{};

  // Every live path whose `waiting-to-start` is recorded.
  final waiting = <JourneyPathId>{};

  Future<void> wait(JourneyPathId path, String why) async {
    if (!waiting.add(path)) return;
    say('${path.hex}: waiting to start: $why');
    await send(
      waitingToStartKind,
      null,
      utf8.encode(jsonEncode(WaitingToStart(path).toJson())),
    );
  }

  Future<void> bringUp(
    JourneyPathId path,
    JourneyId journey,
    JsonObject rules,
  ) async {
    var handed = pools.of(path);
    if (handed == null) {
      if (usesTeamLogin(rules) &&
          started.entries
                  .where((s) => usesTeamLogin(s.value.$2))
                  .where((s) => pools.of(s.key) != null)
                  .length >=
              teamLoginLimit) {
        return wait(path, 'the Team login runs $teamLoginLimit paths');
      }
      switch (pools.handout(path, journey)) {
        case Exhausted(:final why):
          return wait(path, why);
        case Free(assigned: final free):
          try {
            await launcher.wipe(free.suit);
          } on LaunchFailed catch (e) {
            say('${free.suit}: not handed out: ${e.why}');
            return;
          }
          final root = await send(Assigned.kind, null, free.encode());
          pools.take(free, root);
          handed = Handed(free, root);
      }
    }
    final Handed(:assigned, :root) = handed;
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
      for (final handed in pools.live)
        if (handed.assigned.journey == journey) handed.assigned,
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
    waiting.removeWhere((path) => started[path]?.$1 == journey);
    started.removeWhere((_, s) => s.$1 == journey);
    if (!stop) return;
    // The room it made goes to the paths waiting, oldest first.
    for (final MapEntry(key: path, value: (journey, rules))
        in started.entries.toList()) {
      if (pools.of(path) == null) await bringUp(path, journey, rules);
    }
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
      case Entry(:final kind, :final hash, :final body)
          when kind == waitingToStartKind:
        try {
          waiting.add(
            WaitingToStart.fromJson(jsonDecode(utf8.decode(body))).journeyPath,
          );
        } on FormatException catch (e) {
          throw StateError('cannot read the waiting-to-start ${hash.hex}: $e');
        }
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
          case EventAdmitted(placement: UnderJourneyPath() || IntoJourney()):
          case EventDeclined():
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
