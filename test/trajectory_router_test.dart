// Each loop is handed its own trajectory's entries and no other's: the chain
// from its root, and the airlock's outcomes for its proposals.
import 'dart:convert';
import 'dart:typed_data';

import 'package:is_logbook_client/is_logbook_client.dart'
    show Entry, EntryHash, Kind;
import 'package:is_loop_launcher/is_loop_launcher.dart';
import 'package:is_shapes/is_shapes.dart' show EntryId, TrajectoryId;
import 'package:test/test.dart';

void main() {
  final turn = Kind.parse('turn')!;
  final returned = Kind.parse('returned')!;
  var next = 0;

  Entry frame(Kind kind, EntryHash? previous, String body) => Entry(
    hash: EntryHash.parse((++next).toRadixString(16).padLeft(64, '0'))!,
    kind: kind,
    previous: previous,
    recorded: Uint8List.fromList(
      utf8.encode('${kind.name}\n${previous?.hex ?? '-'}\n$body'),
    ),
    checked: false,
  );

  late TrajectoryRouter router;
  final a = TrajectoryId.parse('a1' * 32)!;
  final b = TrajectoryId.parse('b2' * 32)!;
  late Entry rootA, rootB;

  setUp(() {
    router = TrajectoryRouter(
      outcomeKinds: {returned},
      proposalOf: (_, body) => EntryId.parse(utf8.decode(body)),
    );
    rootA = frame(UsersAssignedToTrajectory.kind, null, 'a');
    rootB = frame(UsersAssignedToTrajectory.kind, null, 'b');
    router
      ..rooted(a, rootA)
      ..rooted(b, rootB);
  });

  test("a chain's entries go to its trajectory, and no other's", () {
    final a1 = frame(turn, rootA.hash, 'a1');
    final b1 = frame(turn, rootB.hash, 'b1');
    final a2 = frame(turn, a1.hash, 'a2');
    expect([a1, b1, a2].map(router.route), [a, b, a]);
    expect(router.history(a), [rootA, a1, a2]);
    expect(router.history(b), [rootB, b1]);
  });

  test("an outcome goes to its proposal's trajectory by EntryId; the "
      "airlock's chain doesn't carry it there", () {
    final proposal = frame(turn, rootA.hash, 'propose');
    router.route(proposal);
    final decided = frame(turn, null, 'airlock chain start');
    final outcome = frame(
      returned,
      decided.hash,
      EntryId.of(proposal.recorded).hex,
    );
    expect(router.route(decided), isNull);
    expect(router.route(outcome), a);
    expect(router.route(frame(turn, outcome.hash, 'airlock next')), isNull);
  });

  test('an outcome answering no live proposal, or no proposal, goes '
      'nowhere', () {
    final elsewhere = frame(turn, null, 'x');
    expect(
      router.route(frame(returned, null, EntryId.of(elsewhere.recorded).hex)),
      isNull,
    );
    expect(router.route(frame(returned, null, 'a plain line')), isNull);
  });

  test('an ended trajectory is handed nothing more', () {
    final a1 = frame(turn, rootA.hash, 'a1');
    router.route(a1);
    router.ended(a);
    expect(router.route(frame(turn, a1.hash, 'late')), isNull);
    expect(router.history(a), isEmpty);
  });
}
