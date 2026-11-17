// Each live path's loop is handed its own entries once caught up, and
// nothing after its journey's `ended`; a path with no room waits to start,
// recorded once, until an `ended` makes room.
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:checked_json/checked_json.dart' show JsonObject;
import 'package:is_airlock_api/is_airlock_api.dart' show LoopUser, Suit;
import 'package:is_docking_station/is_docking_station.dart'
    show DecisionEntryKind, JourneyEnded, encodeDecision;
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

  // An `admitted` that starts a journey and its first path, under rules
  // that sign in on the Team login or not; [n] keeps each one's bytes, and
  // so its path and journey, its own.
  Entry admitted(int n, {required bool team}) => entry(
    DecisionEntryKind.admitted,
    null,
    Uint8List.fromList(
      utf8.encode(
        '{"event":"${n.toRadixString(16).padLeft(64, '0')}","by":"rules",'
        '"reading":{"case":"message-said",'
        '"conversation":"teams:19:x;messageid=$n","within":"teams:19:x",'
        '"key":"message:$n","node":{"shape":"UserSaid",'
        '"author":"teams:t/p","source":"19:x;messageid=$n|1","text":"hi"}},'
        '"startsJourneyPath":true,"startsJourney":true,'
        '"rules":{"login":"${team ? 'team' : 'none'}"},"startsTurn":true}',
      ),
    ),
  );

  Entry ended(Entry admitted) {
    final (kind, body) = encodeDecision(
      JourneyEnded(
        EntryHash.parse('e5' * 32)!,
        by: DecidedBy.rules,
        journey: JourneyId.of(admitted.recorded),
      ),
    );
    return entry(kind, null, body);
  }

  JourneyPathId pathOf(Entry admitted) => JourneyPathId.of(admitted.recorded);

  // A record that takes what loop_launcher sends as the journal would, and
  // hands it back on the subscription.
  ({
    StreamController<Subscribed> record,
    List<Entry> sent,
    List<String> said,
    _Launcher launcher,
    Future<void> run,
  })
  launch({required int users, required int teamLoginLimit}) {
    final record = StreamController<Subscribed>();
    final sent = <Entry>[];
    final said = <String>[];
    final launcher = _Launcher();
    final run = runLoopLauncher(
      subscribe: () => record.stream,
      send: (kind, previous, body) async {
        final e = entry(kind, previous, body);
        sent.add(e);
        record.add(e);
        return e.hash;
      },
      pools: Pools(
        loopUsers: [
          for (var n = 1; n <= users; n++) LoopUser.parse('loop-$n')!,
        ],
        suits: [for (var n = 1; n <= users; n++) Suit.parse('suit-$n')!],
      ),
      router: PathRouter(
        outcomeKinds: {returned},
        proposalOf: (_, body) => EntryHash.parse(utf8.decode(body))!,
      ),
      deliver: (_, _) {},
      suitKindOf: (_) => SuitKind.contained,
      usesTeamLogin: (rules) => rules.string('login') == 'team',
      teamLoginLimit: teamLoginLimit,
      launcher: launcher,
      say: said.add,
    );
    return (
      record: record,
      sent: sent,
      said: said,
      launcher: launcher,
      run: run,
    );
  }

  List<String> kindsOf(Iterable<Entry> entries) => [
    for (final e in entries) e.kind!.name,
  ];

  String waitingBody(Entry admitted) =>
      '{"journeyPath":"${pathOf(admitted).hex}"}';

  test('a Team-login path past the limit, or one finding no user free, '
      "waits with no users, recorded once, until an `ended` makes room; "
      'the oldest waiting starts first', () async {
    final l = launch(users: 3, teamLoginLimit: 2);
    final [p1, p2, p3, p4, p5] = [
      admitted(1, team: true),
      admitted(2, team: true),
      admitted(3, team: true),
      admitted(4, team: false),
      admitted(5, team: false),
    ];
    l.record
      ..add(const CaughtUp(null))
      ..add(p1)
      ..add(p2)
      ..add(p3)
      ..add(p4)
      ..add(p5);
    await pumpEventQueue();
    expect(kindsOf(l.sent), [
      'assigned', // p1
      'assigned', // p2
      'waiting-to-start', // p3: the Team login runs 2
      'assigned', // p4: not on the Team login
      'waiting-to-start', // p5: no user free
    ]);
    expect(utf8.decode(l.sent[2].body), waitingBody(p3));
    expect(utf8.decode(l.sent[4].body), waitingBody(p5));
    expect(l.sent[2].previous, isNull, reason: 'on a chain of its own');
    expect(l.launcher.calls.where((c) => c.startsWith('start')), [
      'start loop-1',
      'start loop-2',
      'start loop-3',
    ]);

    l.record.add(ended(p1));
    await pumpEventQueue();
    expect(kindsOf(l.sent.skip(5)), ['assigned'], reason: 'p5 not again');
    expect(
      Assigned.decode(l.sent[5].body)!.journeyPath,
      pathOf(p3),
      reason: 'the oldest waiting, p3, gets the room p1 made',
    );
    expect(l.launcher.calls.skip(9), [
      'stop loop-1',
      'close suit-1',
      'wipe suit-1',
      'open suit-1',
      'start loop-1',
    ]);

    await l.record.close();
    await l.run;
  });

  test('a restart reads who is waiting from the record, and does not '
      'record it again', () async {
    final l = launch(users: 3, teamLoginLimit: 1);
    final [p1, p2] = [admitted(1, team: true), admitted(2, team: true)];
    final waited = entry(
      waitingToStartKind,
      null,
      Uint8List.fromList(utf8.encode(waitingBody(p2))),
    );
    l.record
      ..add(p1)
      ..add(p2)
      ..add(waited)
      ..add(const CaughtUp(null));
    await pumpEventQueue();
    expect(kindsOf(l.sent), ['assigned']);
    expect(Assigned.decode(l.sent.single.body)!.journeyPath, pathOf(p1));
    expect(l.said, isEmpty, reason: 'said once, before the restart');

    await l.record.close();
    await l.run;
  });

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
      usesTeamLogin: (_) => true,
      teamLoginLimit: 4,
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
