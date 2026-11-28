// Each live trajectory's loop is handed its own entries once caught up, and
// nothing after its mission ends; a trajectory with no room waits to start,
// recorded once, until a mission's end makes room.
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:is_airlock_api/is_airlock_api.dart' show LoopUser, Suit;
import 'package:is_docking_station_api/is_docking_station_api.dart'
    show
        DecisionEntryKind,
        MissionEnded,
        OperatorName,
        TrajectoryClosedByOperator,
        encodeDecision;
import 'package:is_flight_rules/is_flight_rules.dart'
    show FlightRules, ProgramsNetwork, WhatMayLeaveThisMachine;
import 'package:is_logbook_client/is_logbook_client.dart'
    show CaughtUp, Entry, Kind, ObjectId, Subscribed;
import 'package:is_model_vocabulary/is_model_vocabulary.dart'
    show ModelAndSignIn, ModelName, ModelSignInName;
import 'package:is_loop_launcher/is_loop_launcher.dart';
import 'package:is_shapes/is_shapes.dart'
    show DecidedBy, MissionId, TrajectoryId;
import 'package:test/test.dart';

void main() {
  final turn = Kind.parse('turn')!;
  final returned = Kind.parse('returned')!;
  Entry entry(
    Kind kind,
    ObjectId? previous,
    Uint8List body, {
    TrajectoryId? on,
  }) {
    final recorded = Uint8List.fromList([
      ...utf8.encode('${kind.name}\n${previous?.hex ?? '-'}\n'),
      ...body,
    ]);
    return Entry(
      id: ObjectId.of(recorded),
      kind: kind,
      previous: previous,
      trajectory: on,
      recorded: recorded,
    );
  }

  Entry assigned(TrajectoryId trajectory, MissionId mission, int n) => entry(
    UsersAssignedToTrajectory.kind,
    null,
    UsersAssignedToTrajectory(
      trajectory: trajectory,
      mission: mission,
      loopUser: LoopUser.parse('loop-$n')!,
      suit: Suit.parse('suit-$n')!,
    ).encode(),
    on: trajectory,
  );

  Entry said(TrajectoryId on, ObjectId previous, String text) =>
      entry(turn, previous, Uint8List.fromList(utf8.encode(text)), on: on);

  // Rules whose model calls may go out as [signIns], starting on the first,
  // with no web grants, no programs and no given tools.
  String rulesJson(List<String> signIns) {
    final names = [for (final s in signIns) ModelSignInName.parse(s)!];
    return jsonEncode(
      FlightRules.of(
        whatMayLeaveThisMachine: WhatMayLeaveThisMachine(
          modelSignInsCallsMayGoOutAs: names,
          fetchesMayReach: const [],
          webRequestsMayReach: const [],
          programsNetwork: ProgramsNetwork.noNetworkOfTheirOwn,
        ),
        startingModel: ModelAndSignIn(
          signIn: names.first,
          model: ModelName.parse('m')!,
        ),
        programsItMayRun: const [],
        programsItNeeds: const [],
        givenTools: const [],
      )!.toJson(),
    );
  }

  // An admission that starts a mission and its first trajectory, under
  // [rulesJson] for [signIns], or [rules] when given. [n] keeps each one's
  // bytes, and so its ids, its own.
  Entry admitted(int n, List<String> signIns, {String? rules}) => entry(
    DecisionEntryKind.eventAdmittedToMission,
    null,
    Uint8List.fromList(
      utf8.encode(
        '{"event":"${n.toRadixString(16).padLeft(64, '0')}","by":"rules",'
        '"translatedEvent":{"case":"message-said",'
        '"addressInExternalSystem":"teams:19:x;messageid=$n",'
        '"containingAddress":"teams:19:x",'
        '"key":"message:$n","node":{"shape":"UserSaid",'
        '"author":"teams:t/p","source":"19:x;messageid=$n|1","text":"hi"}},'
        '"startsTrajectory":true,"startsMission":true,'
        '"rules":${rules ?? rulesJson(signIns)},'
        '"startsTurn":true}',
      ),
    ),
  );

  Entry ended(MissionId mission) {
    final (kind, body) = encodeDecision(
      MissionEnded(
        ObjectId.parse('e5' * 32)!,
        by: DecidedBy.rules,
        mission: mission,
      ),
    );
    return entry(kind, null, body);
  }

  // A person's close of [admitted]'s trajectory.
  Entry closed(Entry admitted, int n) => entry(
    DecisionEntryKind.trajectoryClosed,
    null,
    Uint8List.fromList(
      utf8.encode(
        '{"event":"${(0xc000 + n).toRadixString(16).padLeft(64, '0')}",'
        '"by":"rules","translatedEvent":'
        '{"case":"person-asked-to-close-trajectory",'
        '"addressInExternalSystem":"teams:19:x;messageid=$n",'
        '"containingAddress":"teams:19:x","key":"invoke:$n",'
        '"from":"teams:t/p","message":"19:x;messageid=$n|1",'
        '"trajectory":"${TrajectoryId.of(admitted.recorded).hex}"},'
        '"trajectory":"${TrajectoryId.of(admitted.recorded).hex}",'
        '"mission":"${MissionId.of(admitted.recorded).hex}"}',
      ),
    ),
  );

  TrajectoryId trajectoryOf(Entry admitted) =>
      TrajectoryId.of(admitted.recorded);
  MissionId missionOf(Entry admitted) => MissionId.of(admitted.recorded);

  // An operator's close of [admitted]'s trajectory, which names no event.
  Entry closedByOperator(Entry admitted) {
    final (kind, body) = encodeDecision(
      TrajectoryClosedByOperator(
        trajectory: trajectoryOf(admitted),
        mission: missionOf(admitted),
        operator: OperatorName.parse('nick')!,
        reason: 'stuck in a loop',
      ),
    );
    return entry(kind, null, body);
  }

  // A logbook that takes what loop_launcher sends and hands it back on the
  // subscription.
  ({
    StreamController<Subscribed> logbook,
    List<Entry> sent,
    List<String> said,
    _Machine machine,
    TrajectoryRouter router,
    List<(TrajectoryId, Entry)> delivered,
    List<(Duration, void Function())> scheduled,
    Future<void> run,
  })
  launch({required int users, required String loopLimits}) {
    final logbook = StreamController<Subscribed>();
    final sent = <Entry>[];
    final said = <String>[];
    final machine = _Machine();
    final delivered = <(TrajectoryId, Entry)>[];
    final scheduled = <(Duration, void Function())>[];
    final router = TrajectoryRouter(
      outcomeKinds: {returned},
      proposalOf: (_, body) => ObjectId.parse(utf8.decode(body)),
    );
    final run = runLoopLauncher(
      subscribe: () => logbook.stream,
      send: (kind, previous, body) async {
        final e = entry(kind, previous, body);
        sent.add(e);
        logbook.add(e);
        return e.id;
      },
      pools: Pools(
        loopUsers: [
          for (var n = 1; n <= users; n++) LoopUser.parse('loop-$n')!,
        ],
        suits: [for (var n = 1; n <= users; n++) Suit.parse('suit-$n')!],
      ),
      router: router,
      deliver: (trajectory, entry) => delivered.add((trajectory, entry)),
      loopLimits: LoopLimitPerModelSignIn.parse(loopLimits)!,
      machine: machine,
      say: said.add,
      schedule: (after, then) => scheduled.add((after, then)),
    );
    return (
      logbook: logbook,
      sent: sent,
      said: said,
      machine: machine,
      router: router,
      delivered: delivered,
      scheduled: scheduled,
      run: run,
    );
  }

  List<String> kindsOf(Iterable<Entry> entries) => [
    for (final e in entries) e.kind.name,
  ];

  test("once caught up, a trajectory's entries go to its loop, its history "
      "first, and none after its mission ends", () async {
    final l = launch(users: 2, loopLimits: 'team:4');
    final mission = MissionId.parse('c3' * 32)!;
    final a = TrajectoryId.parse('a1' * 32)!;
    final b = TrajectoryId.parse('b2' * 32)!;
    final rootA = assigned(a, mission, 1);
    final rootB = assigned(b, MissionId.parse('d4' * 32)!, 2);
    final a1 = said(a, rootA.id, 'a1');
    l.logbook
      ..add(rootA)
      ..add(rootB)
      ..add(a1)
      ..add(const CaughtUp(null));
    await pumpEventQueue();
    expect(l.delivered, isEmpty, reason: 'before caught up, history only');
    expect(l.router.history(a), [rootA, a1]);

    final a2 = said(a, a1.id, 'a2');
    final b1 = said(b, rootB.id, 'b1');
    final outcome = entry(
      returned,
      null,
      Uint8List.fromList(utf8.encode(a2.id.hex)),
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
      ..add(said(a, a2.id, 'late'));
    await pumpEventQueue();
    expect(l.delivered, hasLength(3), reason: 'nothing after the end');
    expect(l.router.history(a), isEmpty);
    expect(l.machine.calls, ['stop loop-1', 'close suit-1']);

    await l.logbook.close();
    await l.run;
  });

  test('after a restart, a loop whose trajectory closed while loop_launcher '
      'was down is stopped once caught up, before its user is handed out '
      'again', () async {
    final l = launch(users: 1, loopLimits: 'team:4');
    final p1 = admitted(1, ['team']);
    final p2 = admitted(2, ['team']);
    l.logbook
      ..add(p1)
      ..add(assigned(trajectoryOf(p1), missionOf(p1), 1))
      ..add(closed(p1, 1))
      ..add(p2)
      ..add(const CaughtUp(null));
    await pumpEventQueue();
    expect(l.machine.calls.take(2), ['stop loop-1', 'close suit-1']);
    expect(l.machine.calls.skip(2), [
      'wipe suit-1',
      'open suit-1 noNetworkOfTheirOwn',
      'start loop-1',
    ]);
    expect(
      UsersAssignedToTrajectory.decode(l.sent.single.body)!.trajectory,
      trajectoryOf(p2),
    );

    await l.logbook.close();
    await l.run;
  });

  test('a Team-login trajectory past the limit, or one finding no user '
      'free, waits with no users, recorded once, until a mission ends; '
      'the oldest waiting starts first', () async {
    final l = launch(users: 3, loopLimits: 'team:2,other:9');
    final [p1, p2, p3, p4, p5] = [
      admitted(1, ['team']),
      admitted(2, ['team']),
      admitted(3, ['team']),
      admitted(4, ['other']),
      admitted(5, ['other']),
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
    expect(l.router.history(trajectoryOf(p1)).map((e) => e.id), [
      p1.id,
      l.sent[0].id,
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
    expect(l.machine.calls.skip(15), [
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
    final l = launch(users: 3, loopLimits: 'team:1');
    final [p1, p2] = [
      admitted(1, ['team']),
      admitted(2, ['team']),
    ];
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

  test('each sign-in has its own limit; a trajectory holds a place under '
      'every sign-in its rules allow, and waits on one with no limit '
      'set', () async {
    final l = launch(users: 5, loopLimits: 'claude:1,chatgpt:1');
    final [p1, p2, p3, p4, p5] = [
      admitted(1, ['claude']),
      admitted(2, ['chatgpt']),
      admitted(3, ['claude']),
      admitted(4, ['claude', 'chatgpt']),
      admitted(5, ['other']),
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
      'waiting-to-start',
      'waiting-to-start',
      'waiting-to-start',
    ]);
    expect(l.said, [
      '${trajectoryOf(p3).hex}: waiting to start: '
          'claude is at its limit of 1',
      '${trajectoryOf(p4).hex}: waiting to start: '
          'claude is at its limit of 1',
      '${trajectoryOf(p5).hex}: waiting to start: '
          'no loop limit is set for other',
    ]);

    l.logbook.add(ended(missionOf(p1)));
    await pumpEventQueue();
    expect(kindsOf(l.sent.skip(5)), ['users-assigned-to-trajectory']);
    expect(
      UsersAssignedToTrajectory.decode(l.sent[5].body)!.trajectory,
      trajectoryOf(p3),
      reason: 'the oldest waiting takes the free claude place',
    );

    await l.logbook.close();
    await l.run;
  });

  test("a closed trajectory's loop stops and its users go to the oldest "
      'waiting; its mission and the others run on', () async {
    final l = launch(users: 2, loopLimits: 'team:4');
    final [p1, p2, p3] = [
      admitted(1, ['team']),
      admitted(2, ['team']),
      admitted(3, ['team']),
    ];
    l.logbook
      ..add(const CaughtUp(null))
      ..add(p1)
      ..add(p2)
      ..add(p3);
    await pumpEventQueue();
    expect(kindsOf(l.sent), [
      'users-assigned-to-trajectory',
      'users-assigned-to-trajectory',
      'waiting-to-start',
    ]);

    l.logbook.add(closed(p1, 1));
    await pumpEventQueue();
    expect(l.machine.calls.skip(10), [
      'stop loop-1',
      'close suit-1',
      'wipe suit-1',
      'open suit-1 noNetworkOfTheirOwn',
      'start loop-1',
    ]);
    expect(
      UsersAssignedToTrajectory.decode(l.sent[3].body)!.trajectory,
      trajectoryOf(p3),
    );
    expect(l.router.history(trajectoryOf(p1)), isEmpty);
    expect(l.router.history(trajectoryOf(p2)), isNotEmpty);

    await l.logbook.close();
    await l.run;
  });

  test("an operator's close stops the loop and frees its users as a "
      "person's does", () async {
    final l = launch(users: 1, loopLimits: 'team:4');
    final [p1, p2] = [
      admitted(1, ['team']),
      admitted(2, ['team']),
    ];
    l.logbook
      ..add(const CaughtUp(null))
      ..add(p1)
      ..add(p2);
    await pumpEventQueue();
    expect(kindsOf(l.sent), [
      'users-assigned-to-trajectory',
      'waiting-to-start',
    ]);

    l.logbook.add(closedByOperator(p1));
    await pumpEventQueue();
    expect(l.machine.calls.skip(5), [
      'stop loop-1',
      'close suit-1',
      'wipe suit-1',
      'open suit-1 noNetworkOfTheirOwn',
      'start loop-1',
    ]);
    expect(
      UsersAssignedToTrajectory.decode(l.sent[2].body)!.trajectory,
      trajectoryOf(p2),
    );
    expect(l.router.history(trajectoryOf(p1)), isEmpty);

    await l.logbook.close();
    await l.run;
  });

  test('a closed trajectory that was waiting never starts', () async {
    final l = launch(users: 1, loopLimits: 'team:4');
    final [p1, p2] = [
      admitted(1, ['team']),
      admitted(2, ['team']),
    ];
    l.logbook
      ..add(const CaughtUp(null))
      ..add(p1)
      ..add(p2)
      ..add(closed(p2, 2))
      ..add(ended(missionOf(p1)));
    await pumpEventQueue();
    expect(kindsOf(l.sent), [
      'users-assigned-to-trajectory',
      'waiting-to-start',
    ]);
    expect(l.router.history(trajectoryOf(p2)), isEmpty);

    await l.logbook.close();
    await l.run;
  });

  test('a trajectory allowed two sign-ins uses up both limits', () async {
    final l = launch(users: 3, loopLimits: 'claude:1,chatgpt:1');
    final [p1, p2] = [
      admitted(1, ['claude', 'chatgpt']),
      admitted(2, ['chatgpt']),
    ];
    l.logbook
      ..add(const CaughtUp(null))
      ..add(p1)
      ..add(p2);
    await pumpEventQueue();
    expect(kindsOf(l.sent), [
      'users-assigned-to-trajectory',
      'waiting-to-start',
    ]);

    await l.logbook.close();
    await l.run;
  });

  test('a loop start the machine refuses is tried again after 2s, then 4s, '
      'until it starts, with its users handed out once', () async {
    final l = launch(users: 1, loopLimits: 'team:4');
    l.machine.refusedStarts = 2;
    l.logbook
      ..add(const CaughtUp(null))
      ..add(admitted(1, ['team']));
    await pumpEventQueue();
    expect(
      [for (final (after, _) in l.scheduled) after],
      [const Duration(seconds: 2)],
    );

    l.scheduled.last.$2();
    await pumpEventQueue();
    expect(
      [for (final (after, _) in l.scheduled) after],
      [const Duration(seconds: 2), const Duration(seconds: 4)],
    );

    l.scheduled.last.$2();
    await pumpEventQueue();
    expect(l.scheduled, hasLength(2), reason: 'started, so no more tries');
    expect(l.machine.calls, [
      'stop loop-1',
      'close suit-1',
      'wipe suit-1',
      for (var i = 0; i < 3; i++) ...[
        'open suit-1 noNetworkOfTheirOwn',
        'start loop-1',
      ],
    ]);
    expect(kindsOf(l.sent), ['users-assigned-to-trajectory']);

    await l.logbook.close();
    await l.run;
  });

  test('a trajectory closed while its try waits is not tried', () async {
    final l = launch(users: 1, loopLimits: 'team:4');
    l.machine.refusedStarts = 1;
    final p = admitted(1, ['team']);
    l.logbook
      ..add(const CaughtUp(null))
      ..add(p);
    await pumpEventQueue();
    l.logbook.add(closed(p, 1));
    await pumpEventQueue();
    l.machine.calls.clear();

    l.scheduled.single.$2();
    await pumpEventQueue();
    expect(l.machine.calls, isEmpty);
    expect(l.scheduled, hasLength(1));

    await l.logbook.close();
    await l.run;
  });

  test('an admission under rules this version cannot read stops it, naming '
      'the entry', () async {
    final l = launch(users: 1, loopLimits: 'team:4');
    final old = admitted(1, ['team'], rules: '{"whatMayLeaveThisMachine":{}}');
    final stopped = expectLater(
      l.run,
      throwsA(isA<EntryUnreadable>().having((e) => e.entry, 'entry', old.id)),
    );
    l.logbook.add(old);
    await stopped;
    expect(l.machine.calls, isEmpty);
  });

  test('a try due after the logbook ends does nothing', () async {
    final l = launch(users: 1, loopLimits: 'team:4');
    l.machine.refusedStarts = 1;
    l.logbook
      ..add(const CaughtUp(null))
      ..add(admitted(1, ['team']));
    await pumpEventQueue();
    await l.logbook.close();
    await l.run;
    l.machine.calls.clear();

    l.scheduled.single.$2();
    await pumpEventQueue();
    expect(l.machine.calls, isEmpty);
  });
}

final class _Machine implements StartsAndStopsTrajectoryProcesses {
  final calls = <String>[];

  /// How many loop starts to refuse before one is done.
  var refusedStarts = 0;

  @override
  Future<void> wipeSuit(Suit suit) async => calls.add('wipe $suit');

  @override
  Future<void> openSuitPrograms(Suit suit, ProgramsNetwork network) async =>
      calls.add('open $suit ${network.name}');

  @override
  Future<void> closeSuitPrograms(Suit suit) async => calls.add('close $suit');

  @override
  Future<void> startTrajectoryLoop(LoopUser user) async {
    calls.add('start $user');
    if (refusedStarts > 0) {
      refusedStarts--;
      throw const LaunchFailed('start request repeated too quickly');
    }
  }

  @override
  Future<void> stopTrajectoryLoop(LoopUser user) async =>
      calls.add('stop $user');
}
