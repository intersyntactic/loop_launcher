// Each loop is handed its own trajectory's entries and no other's: those the
// logbook stamps with it, and the airlock's outcomes for its proposals.
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
  final replyChunk = Kind.parse('reply-chunk')!;

  Entry frame(Kind kind, ObjectId? previous, String body, {TrajectoryId? on}) {
    final recorded = Uint8List.fromList(
      utf8.encode('${kind.name}\n${previous?.hex ?? '-'}\n$body'),
    );
    return Entry(
      id: ObjectId.of(recorded),
      kind: kind,
      previous: previous,
      trajectory: on,
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
    rootA = frame(UsersAssignedToTrajectory.kind, null, 'a', on: a);
    rootB = frame(UsersAssignedToTrajectory.kind, null, 'b', on: b);
    router
      ..rooted(a, rootA)
      ..rooted(b, rootB);
  });

  test("an entry goes to the trajectory the logbook stamps it with, and no "
      "other's", () {
    final a1 = frame(turn, rootA.id, 'a1', on: a);
    final b1 = frame(turn, rootB.id, 'b1', on: b);
    final a2 = frame(turn, a1.id, 'a2', on: a);
    expect([a1, b1, a2].map(router.route), [a, b, a]);
    expect(router.history(a), [rootA, a1, a2]);
    expect(router.history(b), [rootB, b1]);
  });

  test('the root of an attaching chain goes to the trajectory it is '
      'stamped with, though no previous link reaches it', () {
    final chunk = frame(replyChunk, null, 'chunk', on: a);
    expect(router.route(chunk), a);
    expect(router.history(a), [rootA, chunk]);
  });

  test('the stamp decides, not the previous link', () {
    final unstamped = frame(turn, rootA.id, 'linked to a, stamped nothing');
    expect(router.route(unstamped), isNull);
    expect(router.history(a), [rootA]);
  });

  test("an outcome goes to its proposal's trajectory by its id; the "
      "airlock's chain doesn't carry it there", () {
    final proposal = frame(turn, rootA.id, 'propose', on: a);
    router.route(proposal);
    final decided = frame(turn, null, 'airlock chain start');
    final outcome = frame(returned, decided.id, proposal.id.hex);
    expect(router.route(decided), isNull);
    expect(router.route(outcome), a);
    expect(router.route(frame(turn, outcome.id, 'airlock next')), isNull);
  });

  test('a body naming a live proposal, under a kind not counted as an '
      'outcome, goes nowhere', () {
    final proposal = frame(turn, rootA.id, 'propose', on: a);
    router.route(proposal);
    final decided = frame(turn, null, 'airlock chain start');
    final other = Kind.parse('another-outcome-kind')!;
    expect(router.route(decided), isNull);
    expect(router.route(frame(other, decided.id, proposal.id.hex)), isNull);
    expect(router.history(a), [rootA, proposal]);
  });

  test('an outcome answering no live proposal, or no proposal, goes '
      'nowhere', () {
    final elsewhere = frame(turn, null, 'x');
    expect(router.route(frame(returned, null, elsewhere.id.hex)), isNull);
    expect(router.route(frame(returned, null, 'a plain line')), isNull);
  });

  test('an admission goes to the trajectory it started or was placed on, '
      'and no other', () {
    final c = TrajectoryId.parse('c3' * 32)!;
    final admission = frame(turn, null, 'admitted');
    router.started(c, admission);
    expect(router.history(c), [admission]);

    final placedB = frame(turn, null, 'placed on b');
    expect(router.placed(b, placedB), isTrue);
    expect(router.history(b), [rootB, placedB]);
    expect(router.history(a), [rootA]);
  });

  test('a relayed event goes to no trajectory', () {
    final raw = frame(Kind.parse('teams-event')!, null, 'teams message');
    expect(router.route(raw), isNull);
    router.started(TrajectoryId.parse('c3' * 32)!, frame(turn, null, 'x'));
    expect(router.history(a), [rootA]);
    expect(router.history(b), [rootB]);
  });

  test('an ended trajectory is handed nothing more', () {
    final a1 = frame(turn, rootA.id, 'a1', on: a);
    router.route(a1);
    router.ended(a);
    expect(router.route(frame(turn, a1.id, 'late', on: a)), isNull);
    expect(router.history(a), isEmpty);
  });
}
