import 'dart:convert';
import 'dart:typed_data';

import 'package:is_airlock_api/is_airlock_api.dart'
    show readOutcomeOfProposedAction;
import 'package:is_logbook_client/is_logbook_client.dart' show Kind, ObjectId;

/// The proposal an outcome-of-proposed-action entry's [body] answers,
/// whatever its result; null when it answers none.
///
/// An action with no proposal is recorded under the same kind as a plain
/// line; it answers no loop. The proposal's EntryId and the logbook's id
/// are both the sha256 of its text.
ObjectId? proposalAnOutcomeAnswers(Kind kind, Uint8List body) {
  final String text;
  try {
    text = utf8.decode(body);
  } on FormatException {
    return null;
  }
  return switch (readOutcomeOfProposedAction(text)) {
    (:final proposed, result: _) => ObjectId.parse(proposed.hex),
    null => null,
  };
}
