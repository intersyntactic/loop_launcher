// An outcome goes to the loop that proposed it, whatever its result, as the
// airlock writes it.
import 'dart:convert';
import 'dart:typed_data';

import 'package:is_airlock_api/is_airlock_api.dart'
    show EntryId, outcomeOfProposedActionKind, proposalRejectedToJson;
import 'package:is_logbook_client/is_logbook_client.dart'
    show Entry, Kind, ObjectId;
import 'package:is_loop_launcher/is_loop_launcher.dart';
import 'package:is_shapes/is_shapes.dart' show TrajectoryId;
import 'package:test/test.dart';

void main() {
  final outcomeKind = Kind.parse(outcomeOfProposedActionKind)!;
  final turn = Kind.parse('turn')!;

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

  test('a refused proposal, nothing ran, goes to the loop whose chain holds '
      'it', () {
    final router = TrajectoryRouter(
      outcomeKinds: {outcomeKind},
      proposalOf: proposalAnOutcomeAnswers,
    );
    final a = TrajectoryId.parse('a1' * 32)!;
    final root = entry(turn, null, 'root');
    router.rooted(a, root);
    final proposal = entry(turn, root.id, 'proposes');
    expect(router.route(proposal), a);

    final refused = entry(
      outcomeKind,
      null,
      jsonEncode(
        proposalRejectedToJson(EntryId.parse(proposal.id.hex)!, 'not allowed'),
      ),
    );
    expect(router.route(refused), a);
    expect(router.history(a).last, refused);
  });

  test('a body that is not an outcome answers no proposal', () {
    expect(
      proposalAnOutcomeAnswers(
        outcomeKind,
        Uint8List.fromList(utf8.encode('{"result":null}')),
      ),
      isNull,
    );
    expect(
      proposalAnOutcomeAnswers(outcomeKind, Uint8List.fromList([0xff])),
      isNull,
    );
  });
}
