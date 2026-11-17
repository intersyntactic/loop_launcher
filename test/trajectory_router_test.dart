// Each loop is handed its own trajectory's entries and no other's: the chain
// from its root, and the airlock's outcomes for its proposals.
import 'dart:convert';
import 'dart:typed_data';

import 'package:is_logbook/is_logbook.dart' show EntryHash;
import 'package:is_logbook/service.dart' show Kind;
import 'package:is_logbook_client/is_logbook_client.dart' show Entry;
import 'package:is_loop_launcher/is_loop_launcher.dart';
import 'package:is_shapes/is_shapes.dart' show TrajectoryId;
import 'package:test/test.dart';

void main() {
  final turn = Kind.parse('turn')!;
  final returned = Kind.parse('returned')!;
  var next = 0;

  Entry frame(Kind kind, EntryHash? previous, String body) {
    final bytes = Uint8List.fromList(
      utf8.encode('${kind.name}\n${previous?.hex ?? '-'}\n$body'),
    );
    return Entry(
      hash: EntryHash.parse((++next).toRadixString(16).padLeft(64, '0'))!,
      kind: kind,
      previous: previous,
      recorded: bytes,
      checked: false,
    );
  }

  late TrajectoryRouter router;
  final a = TrajectoryId.parse('a1' * 32)!;
  final b = TrajectoryId.parse('b2' * 32)!;
  late Entry rootA, rootB;

  setUp(() {
    router = TrajectoryRouter(
      outcomeKinds: {returned},
      proposalOf: (_, body) =>
          EntryHash.parse(utf8.decode(body)) ??
          (throw const FormatException('not a proposal hash')),
    );
    rootA = frame(UsersAssignedToTrajectory.kind, null, '');
    rootB = frame(UsersAssignedToTrajectory.kind, null, '');
    router.rooted(a, rootA.hash);
    router.rooted(b, rootB.hash);
  });

  test("a chain's entries go to its path, and no other's", () {
    final a1 = frame(turn, rootA.hash, 'a1');
    final b1 = frame(turn, rootB.hash, 'b1');
    final a2 = frame(turn, a1.hash, 'a2');
    expect([a1, b1, a2].map(router.route), [a, b, a]);
    expect(router.history(a), [a1, a2]);
    expect(router.history(b), [b1]);
  });

  test("an outcome goes to its proposal's path; the airlock's chain doesn't "
      'carry it there', () {
    final proposal = frame(turn, rootA.hash, 'propose');
    router.route(proposal);
    final decided = frame(turn, null, 'airlock chain start');
    final outcome = frame(returned, decided.hash, proposal.hash.hex);
    expect(router.route(decided), isNull);
    expect(router.route(outcome), a);
    // The outcome is not on A's chain: an entry after it is not A's.
    expect(router.route(frame(turn, outcome.hash, 'airlock next')), isNull);
  });

  test("an outcome for no live path's proposal goes nowhere", () {
    final elsewhere = frame(turn, null, 'x');
    expect(router.route(frame(returned, null, elsewhere.hash.hex)), isNull);
  });

  test('an outcome that cannot be read throws, not skipped', () {
    expect(
      () => router.route(frame(returned, null, 'garbage')),
      throwsFormatException,
    );
  });

  test('an ended path is handed nothing more', () {
    final a1 = frame(turn, rootA.hash, 'a1');
    router.route(a1);
    router.ended(a);
    expect(router.route(frame(turn, a1.hash, 'late')), isNull);
    expect(router.history(a), isEmpty);
  });
}
