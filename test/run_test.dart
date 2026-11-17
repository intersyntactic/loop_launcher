// Each live trajectory's loop is handed its own entries once caught up, and
// nothing after its mission ends; a trajectory with no room waits to start,
// recorded once, until a mission's end makes room.
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:is_airlock_api/is_airlock_api.dart' show LoopUser, Suit;
import 'package:is_docking_station/is_docking_station.dart'
    show DecisionEntryKind, MissionEnded, encodeDecision;
import 'package:is_effects/is_effects.dart' show ModelSignInName;
import 'package:is_flight_rules/is_flight_rules.dart' show ProgramsNetwork;
import 'package:is_logbook/is_logbook.dart' show EntryHash;
import 'package:is_logbook/service.dart' show Kind;
import 'package:is_logbook_client/is_logbook_client.dart'
    show CaughtUp, Entry, Subscribed;
import 'package:is_loop_launcher/is_loop_launcher.dart';
import 'package:is_shapes/is_shapes.dart'
    show DecidedBy, EntryId, MissionId, TrajectoryId;
import 'package:test/test.dart';

void main() {
  final turn = Kind.parse('turn')!;
  final returned = Kind.parse('returned')!;
  final team = ModelSignInName.parse('team')!;
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

  Entry assigned(TrajectoryId trajectory, MissionId mission, int n) => entry(
    UsersAssignedToTrajectory.kind,
    null,
    UsersAssignedToTrajectory(
      trajectory: trajectory,
      mission: mission,
      loopUser: LoopUser.parse('loop-$n')!,
      suit: Suit.parse('suit-$n')!,
    ).encode(),
  );

  Entry said(EntryHash previous, String text) =>
      entry(turn, previous, Uint8List.fromList(utf8.encode(text)));

  // An admission that starts a mission and its first trajectory, under
  // rules whose model calls go out as the Team login or not. [n] keeps each
  // one's bytes, and so its ids, its own.
  Entry admitted(int n, {required bool team}) => entry(
    DecisionEntryKind.eventAdmittedToMission,
    null,
    Uint8List.fromList(
      utf8.encode(
        '{"event":"${n.toRadixString(16).padLeft(64, '0')}","by":"rules",'
        '"reading":{"case":"message-said",'
        '"addressInExternalSystem":"teams:19:x;messageid=$n",'
        '"containingAddress":"teams:19:x",'
        '"key":"message:$n","node":{"shape":"UserSaid",'
        '"author":"teams:t/p","source":"19:x;messageid=$n|1","text":"hi"}},'
        '"startsTrajectory":true,"startsMission":true,'
        '"rules":{"modelSignInsCallsMayGoOutAs":[${team ? '"team"' : ''}],'
        '"sitesTheWebDriverMayReach":[],'
        '"programsNetwork":"noNetworkOfTheirOwn"},"startsTurn":true}',
      ),
    ),
  );

  Entry ended(MissionId mission) {
    final (kind, body) = encodeDecision(
      MissionEnded(
        EntryHash.parse('e5' * 32)!,
        by: DecidedBy.rules,
        mission: mission,
      ),
    );
    return entry(kind, null, body);
  }

  TrajectoryId trajectoryOf(Entry admitted) =>
      TrajectoryId.of(admitted.recorded);
  MissionId missionOf(Entry admitted) => MissionId.of(admitted.recorded);

  // A logbook that takes what loop_launcher sends and hands it back on the
  // subscription.
  ({
    StreamController<Subscribed> logbook,
    List<Entry> sent,
    List<String> said,
    _Machine machine,
    TrajectoryRouter router,
    List<(TrajectoryId, Entry)> delivered,
    Future<void> run,
  })
  launch({required int users, required int teamLoginLimit}) {
    final logbook = StreamController<Subscribed>();
    final sent = <Entry>[];
    final said = <String>[];
    final machine = _Machine();
    final delivered = <(TrajectoryId, Entry)>[];
    final router = TrajectoryRouter(
      outcomeKinds: {returned},
      proposalOf: (_, body) => EntryId.parse(utf8.decode(body)),
    );
    final run = runLoopLauncher(
      subscribe: () => logbook.stream,
      send: (kind, previous, body) async {
        final e = entry(kind, previous, body);
        sent.add(e);
        logbook.add(e);
        return e.hash;
      },
      pools: Pools(
        loopUsers: [
          for (var n = 1; n <= users; n++) LoopUser.parse('loop-$n')!,
        ],
        suits: [for (var n = 1; n <= users; n++) Suit.parse('suit-$n')!],
      ),
      router: router,
      deliver: (trajectory, entry) => delivered.add((trajectory, entry)),
      teamLogin: team,
      teamLoginLimit: teamLoginLimit,
      machine: machine,
      say: said.add,
    );
    return (
      logbook: logbook,
      sent: sent,
      said: said,
      machine: machine,
      router: router,
      delivered: delivered,
      run: run,
    );
  }

  List<String> kindsOf(Iterable<Entry> entries) => [
    for (final e in entries) e.kind!.name,
  ];

  test("once caught up, a trajectory's entries go to its loop, its history "
      "first, and none after its mission ends", () async {
    final l = launch(users: 2, teamLoginLimit: 4);
    final mission = MissionId.parse('c3' * 32)!;
    final a = TrajectoryId.parse('a1' * 32)!;
    final b = TrajectoryId.parse('b2' * 32)!;
    final rootA = assigned(a, mission, 1);
    final rootB = assigned(b, MissionId.parse('d4' * 32)!, 2);
    final a1 = said(rootA.hash, 'a1');
    l.logbook
      ..add(rootA)
      ..add(rootB)
      ..add(a1)
      ..add(const CaughtUp(null));
    await pumpEventQueue();
    expect(l.delivered, isEmpty, reason: 'before caught up, history only');
    expect(l.router.history(a), [rootA, a1]);

    final a2 = said(a1.hash, 'a2');
    final b1 = said(rootB.hash, 'b1');
    final outcome = entry(
      returned,
      null,
      Uint8List.fromList(utf8.encode(EntryId.of(a2.recorded).hex)),
    );
    l.logbook
      ..add(a2)
      ..add(b1)
      ..add(entry(turn, null, Uint8List(0)))
      ..add(outcome);
    await pumpEventQueue();
    expect(l.delivered, [(a, a2), (b, b1), (a, outcome)]);

    l.logbook
      ..add(ended(mission))
      ..add(said(a2.hash, 'late'));
    await pumpEventQueue();
    expect(l.delivered, hasLength(3), reason: 'nothing after the end');
    expect(l.router.history(a), isEmpty);
    expect(l.machine.calls, ['stop loop-1', 'close suit-1']);

    await l.logbook.close();
    await l.run;
  });

  test('a Team-login trajectory past the limit, or one finding no user '
      'free, waits with no users, recorded once, until a mission ends; '
      'the oldest waiting starts first', () async {
    final l = launch(users: 3, teamLoginLimit: 2);
    final [p1, p2, p3, p4, p5] = [
      admitted(1, team: true),
      admitted(2, team: true),
      admitted(3, team: true),
      admitted(4, team: false),
      admitted(5, team: false),
    ];
    l.logbook
      ..add(const CaughtUp(null))
      ..add(p1)
      ..add(p2)
      ..add(p3)
      ..add(p4)
      ..add(p5);
    await pumpEventQueue();
    expect(kindsOf(l.sent), [
      'users-assigned-to-trajectory',
      'users-assigned-to-trajectory',
      'waiting-to-start', // p3: the Team login is at its limit
      'users-assigned-to-trajectory', // p4: not on the Team login
      'waiting-to-start', // p5: no user free
    ]);
    expect(
      utf8.decode(l.sent[2].body),
      '{"trajectory":"${trajectoryOf(p3).hex}"}',
    );
    expect(l.sent[2].previous, isNull);
    final first = UsersAssignedToTrajectory.decode(l.sent[0].body)!;
    expect(first.trajectory, trajectoryOf(p1));
    expect(first.mission, missionOf(p1), reason: 'ids hash the bytes');
    expect(l.router.history(trajectoryOf(p1)).map((e) => e.hash), [
      p1.hash,
      l.sent[0].hash,
    ], reason: 'the feed starts with the admission, then the root');
    expect(l.machine.calls.where((c) => c.startsWith('start')), [
      'start loop-1',
      'start loop-2',
      'start loop-3',
    ]);

    l.logbook.add(ended(missionOf(p1)));
    await pumpEventQueue();
    expect(kindsOf(l.sent.skip(5)), ['users-assigned-to-trajectory']);
    expect(
      UsersAssignedToTrajectory.decode(l.sent[5].body)!.trajectory,
      trajectoryOf(p3),
    );
    expect(l.machine.calls.skip(9), [
      'stop loop-1',
      'close suit-1',
      'wipe suit-1',
      'open suit-1 noNetworkOfTheirOwn',
      'start loop-1',
    ]);

    await l.logbook.close();
    await l.run;
  });

  test('a restart reads who is waiting from the logbook, and does not '
      'record it again', () async {
    final l = launch(users: 3, teamLoginLimit: 1);
    final [p1, p2] = [admitted(1, team: true), admitted(2, team: true)];
    l.logbook
      ..add(p1)
      ..add(p2)
      ..add(
        entry(
          waitingToStartKind,
          null,
          Uint8List.fromList(
            utf8.encode('{"trajectory":"${trajectoryOf(p2).hex}"}'),
          ),
        ),
      )
      ..add(const CaughtUp(null));
    await pumpEventQueue();
    expect(kindsOf(l.sent), ['users-assigned-to-trajectory']);
    expect(l.said, isEmpty);

    await l.logbook.close();
    await l.run;
  });
}

final class _Machine implements StartsAndStopsTrajectoryProcesses {
  final calls = <String>[];

  @override
  Future<void> wipeSuit(Suit suit) async => calls.add('wipe $suit');

  @override
  Future<void> openSuitPrograms(Suit suit, ProgramsNetwork network) async =>
      calls.add('open $suit ${network.name}');

  @override
  Future<void> closeSuitPrograms(Suit suit) async => calls.add('close $suit');

  @override
  Future<void> startTrajectoryLoop(LoopUser user) async =>
      calls.add('start $user');

  @override
  Future<void> stopTrajectoryLoop(LoopUser user) async =>
      calls.add('stop $user');
}
