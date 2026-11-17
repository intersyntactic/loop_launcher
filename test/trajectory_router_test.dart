// Each loop is handed its own trajectory's entries and no other's: the chain
// from its root, and the airlock's outcomes for its proposals.
import 'dart:convert';
import 'dart:typed_data';

import 'package:is_logbook_client/is_logbook_client.dart'
    show Entry, Kind, ObjectId;
import 'package:is_loop_launcher/is_loop_launcher.dart';
import 'package:is_shapes/is_shapes.dart' show TrajectoryId;
import 'package:test/test.dart';

void main() {
  final turn = Kind.parse('turn')!;
  final returned = Kind.parse('returned')!;

  Entry frame(Kind kind, ObjectId? previous, String body) {
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

  late TrajectoryRouter router;
  final a = TrajectoryId.parse('a1' * 32)!;
  final b = TrajectoryId.parse('b2' * 32)!;
  late Entry rootA, rootB;

  setUp(() {
    router = TrajectoryRouter(
      outcomeKinds: {returned},
      proposalOf: (_, body) => ObjectId.parse(utf8.decode(body)),
    );
    rootA = frame(UsersAssignedToTrajectory.kind, null, 'a');
    rootB = frame(UsersAssignedToTrajectory.kind, null, 'b');
    router
      ..rooted(a, rootA)
      ..rooted(b, rootB);
  });

  test("a chain's entries go to its trajectory, and no other's", () {
    final a1 = frame(turn, rootA.id, 'a1');
    final b1 = frame(turn, rootB.id, 'b1');
    final a2 = frame(turn, a1.id, 'a2');
    expect([a1, b1, a2].map(router.route), [a, b, a]);
    expect(router.history(a), [rootA, a1, a2]);
    expect(router.history(b), [rootB, b1]);
  });

  test("an outcome goes to its proposal's trajectory by its id; the "
      "airlock's chain doesn't carry it there", () {
    final proposal = frame(turn, rootA.id, 'propose');
    router.route(proposal);
    final decided = frame(turn, null, 'airlock chain start');
    final outcome = frame(returned, decided.id, proposal.id.hex);
    expect(router.route(decided), isNull);
    expect(router.route(outcome), a);
    expect(router.route(frame(turn, outcome.id, 'airlock next')), isNull);
  });

  test('an outcome answering no live proposal, or no proposal, goes '
      'nowhere', () {
    final elsewhere = frame(turn, null, 'x');
    expect(router.route(frame(returned, null, elsewhere.id.hex)), isNull);
    expect(router.route(frame(returned, null, 'a plain line')), isNull);
  });

  test('an ended trajectory is handed nothing more', () {
    final a1 = frame(turn, rootA.id, 'a1');
    router.route(a1);
    router.ended(a);
    expect(router.route(frame(turn, a1.id, 'late')), isNull);
    expect(router.history(a), isEmpty);
  });
}
