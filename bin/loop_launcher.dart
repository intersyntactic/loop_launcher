import 'dart:convert';
import 'dart:io';

import 'package:is_airlock_api/is_airlock_api.dart'
    show
        LoopUser,
        Suit,
        outcomeOfProposedActionKind,
        readOutcomeOfProposedAction;
import 'package:is_logbook_client/is_logbook_client.dart';
import 'package:is_loop_launcher/is_loop_launcher.dart';

/// Exit status for a missing or unreadable setting; systemd should not
/// restart on it.
const badConfig = 78;

/// Printed once every loop's feed is bound.
const startupLine = 'loop_launcher: feeds bound, following the logbook';

String _setting(String name) {
  final value = Platform.environment[name];
  if (value == null || value.isEmpty) {
    stderr.writeln('loop_launcher: $name is not set');
    exit(badConfig);
  }
  return value;
}

int _count(String name) =>
    int.tryParse(_setting(name)) ??
    (() {
      stderr.writeln('loop_launcher: $name is not a whole number');
      exit(badConfig);
    })();

Future<void> main() async {
  final readSocket = _setting('LOGBOOK_READ_SOCKET');
  final writeSocket = _setting('LOGBOOK_WRITE_SOCKET');
  final poolSize = _count('POOL_SIZE');
  final loopLimits =
      LoopLimitPerModelSignIn.parse(_setting('LOOP_LIMIT_PER_MODEL_SIGN_IN')) ??
      (() {
        stderr.writeln(
          'loop_launcher: LOOP_LIMIT_PER_MODEL_SIGN_IN is not '
          'sign-in:count pairs, each sign-in once',
        );
        exit(badConfig);
      })();

  final feedDir = _setting('FEED_DIR');

  final reader = LogbookReader(readSocket);
  final writer = LogbookWriter(writeSocket);
  final loopUsers = [
    for (var n = 1; n <= poolSize; n++) LoopUser.parse('loop-$n')!,
  ];
  final pools = Pools(
    loopUsers: loopUsers,
    suits: [for (var n = 1; n <= poolSize; n++) Suit.parse('suit-$n')!],
  );
  final router = TrajectoryRouter(
    outcomeKinds: {Kind.parse(outcomeOfProposedActionKind)!},
    // An action with no proposal is recorded under the same kind as a plain
    // line; it answers no loop. The proposal's EntryId and the logbook's id
    // are both the sha256 of its text.
    proposalOf: (_, body) {
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
    },
  );
  final feeds = LoopFeeds(
    dir: feedDir,
    router: router,
    trajectoryOf: pools.heldBy,
  );
  await feeds.bind(loopUsers);
  stdout.writeln(startupLine);

  await runLoopLauncher(
    subscribe: reader.subscribe,
    send: (kind, previous, body) async =>
        switch (await writer.write(kind, body, previous: previous)) {
          Written(:final entry) || AlreadyRecorded(:final entry) => entry,
          NotTip(:final tip) => throw StateError('$kind: not tip, $tip is'),
          WriteRefused(:final why) => throw StateError('$kind refused: $why'),
          WriteFailed(:final why) => throw StateError('$kind failed: $why'),
          Unanswered(:final why) => throw StateError('$kind unanswered: $why'),
        },
    pools: pools,
    router: router,
    deliver: feeds.deliver,
    loopLimits: loopLimits,
    machine: SystemdUnits(),
    say: (line) => stdout.writeln(line),
  );
  stderr.writeln('loop_launcher: the logbook stream ended');
  exit(1);
}
