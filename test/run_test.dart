// Each live path's loop is handed its own entries once caught up, and
// nothing after its journey's `ended`.
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:checked_json/checked_json.dart' show JsonObject;
import 'package:is_airlock_api/is_airlock_api.dart' show LoopUser, Suit;
import 'package:is_docking_station/is_docking_station.dart'
    show JourneyEnded, encodeDecision;
import 'package:is_journal/is_journal.dart' show EntryHash;
import 'package:is_journal/service.dart' show Kind;
import 'package:is_journal_client/is_journal_client.dart'
    show CaughtUp, Entry, Subscribed;
import 'package:is_loop_launcher/is_loop_launcher.dart';
import 'package:is_shapes/is_shapes.dart'
    show DecidedBy, JourneyId, JourneyPathId;
import 'package:test/test.dart';

void main() {
  final turn = Kind.parse('turn')!;
  final returned = Kind.parse('returned')!;
  final journey = JourneyId.parse('c3' * 32)!;
  final a = JourneyPathId.parse('a1' * 32)!;
  final b = JourneyPathId.parse('b2' * 32)!;
  var next = 0;

  Entry entry(Kind kind, EntryHash? previous, Uint8List body) => Entry(
    hash: EntryHash.parse((++next).toRadixString(16).padLeft(64, '0'))!,
    kind: kind,
    previous: previous,
    recorded: Uint8List.fromList([
      ...utf8.encode('${kind.name}\n${previous?.hex ?? '-'}\n'),
      ...body,
    ]),
    checked: false,
  );

  Entry assigned(JourneyPathId path, JourneyId journey, int n) => entry(
    Assigned.kind,
    null,
    Assigned(
      journeyPath: path,
      journey: journey,
      loopUser: LoopUser.parse('loop-$n')!,
      suit: Suit.parse('suit-$n')!,
    ).encode(),
  );

  Entry said(EntryHash previous, String text) =>
      entry(turn, previous, Uint8List.fromList(utf8.encode(text)));

  test("once caught up, a path's entries go to its loop, its history first, "
      "and none after its journey's `ended`", () async {
    final record = StreamController<Subscribed>();
    final router = PathRouter(
      outcomeKinds: {returned},
      proposalOf: (_, body) => EntryHash.parse(utf8.decode(body))!,
    );
    final delivered = <(JourneyPathId, Entry)>[];
    final launcher = _Launcher();
    final run = runLoopLauncher(
      subscribe: () => record.stream,
      send: (_, _, _) => throw StateError('nothing is handed out'),
      pools: Pools(
        loopUsers: [LoopUser.parse('loop-1')!, LoopUser.parse('loop-2')!],
        suits: [Suit.parse('suit-1')!, Suit.parse('suit-2')!],
      ),
      router: router,
      deliver: (path, entry) => delivered.add((path, entry)),
      suitKindOf: (_) => SuitKind.contained,
      launcher: launcher,
      say: (line) => fail(line),
    );

    final rootA = assigned(a, journey, 1);
    final rootB = assigned(b, JourneyId.parse('d4' * 32)!, 2);
    final a1 = said(rootA.hash, 'a1');
    record
      ..add(rootA)
      ..add(rootB)
      ..add(a1)
      ..add(const CaughtUp(null));
    await pumpEventQueue();
    expect(delivered, isEmpty, reason: 'before caught up, history only');
    expect(router.history(a), [a1]);

    final a2 = said(a1.hash, 'a2');
    final b1 = said(rootB.hash, 'b1');
    final elsewhere = entry(turn, null, Uint8List(0));
    final outcome = entry(
      returned,
      null,
      Uint8List.fromList(utf8.encode(a2.hash.hex)),
    );
    record
      ..add(a2)
      ..add(b1)
      ..add(elsewhere)
      ..add(outcome);
    await pumpEventQueue();
    expect(delivered, [(a, a2), (b, b1), (a, outcome)]);
    expect(router.history(a), [a1, a2, outcome]);

    final (kind, body) = encodeDecision(
      JourneyEnded(
        EntryHash.parse('e5' * 32)!,
        by: DecidedBy.rules,
        journey: journey,
      ),
    );
    record
      ..add(entry(kind, null, body))
      ..add(said(a2.hash, 'late'));
    await pumpEventQueue();
    expect(delivered, hasLength(3), reason: 'nothing after `ended`');
    expect(router.history(a), isEmpty);
    expect(launcher.calls, ['stop loop-1', 'close suit-1']);

    await record.close();
    await run;
  });
}

/// A [Launcher] that only says what it was asked to do.
final class _Launcher implements Launcher {
  final calls = <String>[];

  @override
  Future<void> wipe(Suit suit) async => calls.add('wipe $suit');

  @override
  Future<void> openPrograms(Suit suit, SuitKind kind) async =>
      calls.add('open $suit');

  @override
  Future<void> closePrograms(Suit suit) async => calls.add('close $suit');

  @override
  Future<void> stop(LoopUser user) async => calls.add('stop $user');

  @override
  Future<void> start(
    LoopUser user,
    JourneyPathId path,
    EntryHash root,
    JsonObject rules,
  ) async => calls.add('start $user');
}
