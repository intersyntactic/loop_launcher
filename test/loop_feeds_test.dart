// A loop reads its feed with the logbook's own client and gets its
// trajectory's entries and no other's, then each new one live.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:is_airlock_api/is_airlock_api.dart' show LoopUser;
import 'package:is_logbook_client/is_logbook_client.dart';
import 'package:is_loop_launcher/is_loop_launcher.dart';
import 'package:is_shapes/is_shapes.dart' show EntryId, TrajectoryId;
import 'package:test/test.dart';

void main() {
  final turn = Kind.parse('turn')!;
  final returned = Kind.parse('returned')!;
  final loop1 = LoopUser.parse('loop-1')!;
  final loop2 = LoopUser.parse('loop-2')!;
  final a = TrajectoryId.parse('a1' * 32)!;
  final b = TrajectoryId.parse('b2' * 32)!;
  var next = 0;

  Entry entry(Kind kind, EntryHash? previous, String body) => Entry(
    hash: EntryHash.parse((++next).toRadixString(16).padLeft(64, '0'))!,
    kind: kind,
    previous: previous,
    recorded: Uint8List.fromList(
      utf8.encode('${kind.name}\n${previous?.hex ?? '-'}\n$body'),
    ),
    checked: false,
  );

  late Directory dir;
  late TrajectoryRouter router;
  late LoopFeeds feeds;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('feeds');
    await Directory('${dir.path}/loop-1').create();
    await Directory('${dir.path}/loop-2').create();
    router = TrajectoryRouter(
      outcomeKinds: {returned},
      proposalOf: (_, body) => EntryId.parse(utf8.decode(body)),
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

  test(
    "a loop gets its own trajectory's entries, an outcome by its "
    "proposal's EntryId, and nothing of another's; then new ones live",
    () async {
      final rootA = entry(UsersAssignedToTrajectory.kind, null, 'a');
      final rootB = entry(UsersAssignedToTrajectory.kind, null, 'b');
      router
        ..rooted(a, rootA)
        ..rooted(b, rootB);
      final proposal = entry(turn, rootA.hash, 'propose');
      final outcome = entry(returned, null, EntryId.of(proposal.recorded).hex);
      for (final e in [
        proposal,
        entry(turn, rootB.hash, 'b only'),
        // An outcome naming the proposal's EntryHash instead must not match.
        entry(returned, null, proposal.hash.hex),
        // A `returned` that answers no proposal goes nowhere.
        entry(returned, null, 'not a proposal'),
        outcome,
      ]) {
        router.route(e);
      }

      final feed = LogbookReader(feeds.pathOf(loop1)).subscribe();
      final got = StreamIterator(feed);
      final seen = <EntryHash>[];
      while (await got.moveNext() && got.current is Entry) {
        seen.add((got.current as Entry).hash);
      }
      expect(seen, [rootA.hash, proposal.hash, outcome.hash]);
      expect(got.current, isA<CaughtUp>());

      final live = entry(turn, proposal.hash, 'live');
      router.route(live);
      feeds.deliver(a, live);
      feeds.deliver(b, entry(turn, rootB.hash, 'not for a'));
      expect(await got.moveNext(), isTrue);
      expect((got.current as Entry).hash, live.hash);
      await got.cancel();
    },
  );

  test('anything but subscribe from start is refused', () async {
    final socket = await Socket.connect(
      InternetAddress(feeds.pathOf(loop1), type: InternetAddressType.unix),
      0,
    );
    socket.add(ascii.encode('tip ${'a' * 64}\n'));
    expect(await utf8.decoder.bind(socket).join(), 'refused only subscribe\n');
  });
}
