// A loop reads its feed with the logbook's own client and gets its
// trajectory's entries and no other's, then each new one live.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:is_airlock_api/is_airlock_api.dart' show LoopUser;
import 'package:is_admission_vocabulary/is_admission_vocabulary.dart'
    show DecisionEntryKind;
import 'package:is_logbook_client/is_logbook_client.dart';
import 'package:is_loop_launcher/is_loop_launcher.dart';
import 'package:is_shapes/is_shapes.dart' show TrajectoryId;
import 'package:test/test.dart';

void main() {
  final turn = Kind.parse('turn')!;
  final returned = Kind.parse('returned')!;
  final loop1 = LoopUser.parse('loop-1')!;
  final loop2 = LoopUser.parse('loop-2')!;
  final a = TrajectoryId.parse('a1' * 32)!;
  final b = TrajectoryId.parse('b2' * 32)!;
  Entry entry(Kind kind, ObjectId? previous, String body) {
    final recorded = Uint8List.fromList(
      utf8.encode('${kind.name}\n${previous?.hex ?? '-'}\n$body'),
    );
    return Entry(
      id: ObjectId.of(recorded),
      kind: kind,
      previous: previous,
      recorded: recorded,
    );
  }

  late Directory dir;
  late TrajectoryRouter router;
  late LoopFeeds feeds;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('feeds');
    await Directory('${dir.path}/loop-1').create();
    await Directory('${dir.path}/loop-2').create();
    router = TrajectoryRouter(
      eventKinds: {Kind.parse('event')!},
      outcomeKinds: {returned},
      proposalOf: (_, body) => ObjectId.parse(utf8.decode(body)),
    );
    feeds = LoopFeeds(
      dir: dir.path,
      router: router,
      trajectoryOf: (user) => user == loop1
          ? a
          : user == loop2
          ? b
          : null,
    );
    await feeds.bind([loop1, loop2]);
  });

  tearDown(() => dir.delete(recursive: true));

  test("a loop gets its own trajectory's entries, an outcome by its "
      "proposal's id, and nothing of another's; then new ones live", () async {
    final rootA = entry(UsersAssignedToTrajectory.kind, null, 'a');
    final rootB = entry(UsersAssignedToTrajectory.kind, null, 'b');
    router
      ..rooted(a, rootA)
      ..rooted(b, rootB);
    final proposal = entry(turn, rootA.id, 'propose');
    final outcome = entry(returned, null, proposal.id.hex);
    for (final e in [
      proposal,
      entry(turn, rootB.id, 'b only'),
      // A `returned` that answers no proposal goes nowhere.
      entry(returned, null, 'not a proposal'),
      outcome,
    ]) {
      router.route(e);
    }

    final feed = LogbookReader(feeds.pathOf(loop1)).subscribe();
    final got = StreamIterator(feed);
    final seen = <ObjectId>[];
    while (await got.moveNext() && got.current is Entry) {
      seen.add((got.current as Entry).id);
    }
    expect(seen, [rootA.id, proposal.id, outcome.id]);
    expect(got.current, isA<CaughtUp>());

    final live = entry(turn, proposal.id, 'live');
    router.route(live);
    feeds.deliver(a, live);
    feeds.deliver(b, entry(turn, rootB.id, 'not for a'));
    expect(await got.moveNext(), isTrue);
    expect((got.current as Entry).id, live.id);
    await got.cancel();
  });

  test('a loop subscribed to turn, admission and event kinds gets each raw '
      'event just before its admission, replayed and live', () async {
    final admittedKind = DecisionEntryKind.eventAdmittedToMission;
    final eventKind = Kind.parse('event')!;
    final raw = entry(eventKind, null, 'first message');
    final admission = entry(admittedKind, null, raw.id.hex);
    final rootA = entry(UsersAssignedToTrajectory.kind, null, 'a');
    router
      ..route(raw)
      ..started(a, admission, raw.id)
      ..rooted(a, rootA);
    final firstTurn = entry(turn, rootA.id, 'reply');
    router.route(firstTurn);

    final feed = LogbookReader(
      feeds.pathOf(loop1),
    ).subscribe(kinds: {turn, admittedKind, eventKind});
    final got = StreamIterator(feed);
    final seen = <ObjectId>[];
    while (await got.moveNext() && got.current is Entry) {
      seen.add((got.current as Entry).id);
    }
    expect(seen, [raw.id, admission.id, firstTurn.id]);

    final rawLive = entry(eventKind, null, 'second message');
    final placedLive = entry(admittedKind, null, rawLive.id.hex);
    router.route(rawLive);
    for (final e in router.placed(a, placedLive, rawLive.id)!) {
      feeds.deliver(a, e);
    }
    for (final want in [rawLive, placedLive]) {
      expect(await got.moveNext(), isTrue);
      final e = got.current as Entry;
      expect(e.id, want.id);
      expect(e.recorded, want.recorded);
    }
    await got.cancel();
  });

  test('anything but subscribe from start is refused', () async {
    final socket = await Socket.connect(
      InternetAddress(feeds.pathOf(loop1), type: InternetAddressType.unix),
      0,
    );
    socket.add(ascii.encode('tip ${'a' * 64}\n'));
    expect(await utf8.decoder.bind(socket).join(), 'refused only subscribe\n');
  });
}
