import 'dart:io';

import 'package:is_airlock_api/is_airlock_api.dart' show LoopUser, Suit;
import 'package:is_effects/is_effects.dart' show ModelSignInName;
import 'package:is_logbook_client/is_logbook_client.dart';
import 'package:is_loop_launcher/is_loop_launcher.dart';

/// Exit status for a missing or unreadable setting; systemd should not
/// restart on it.
const badConfig = 78;

const startupLine = 'loop_launcher: following the logbook';

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
  final teamLoginLimit = _count('TEAM_LOGIN_LIMIT');
  final teamLogin =
      ModelSignInName.parse(_setting('TEAM_LOGIN')) ??
      (() {
        stderr.writeln('loop_launcher: TEAM_LOGIN is not a sign-in name');
        exit(badConfig);
      })();

  final reader = LogbookReader(readSocket);
  final writer = LogbookWriter(writeSocket);
  stdout.writeln(startupLine);

  await runLoopLauncher(
    subscribe: reader.subscribe,
    send: (kind, previous, body) async =>
        switch (await writer.write(kind, body, previous: previous)) {
          Written(:final entry) => entry,
          NotTip(:final tip) => throw StateError('$kind: not tip, $tip is'),
          WriteRefused(:final why) => throw StateError('$kind refused: $why'),
          WriteFailed(:final why) => throw StateError('$kind failed: $why'),
          Unanswered(:final why) => throw StateError('$kind unanswered: $why'),
        },
    pools: Pools(
      loopUsers: [
        for (var n = 1; n <= poolSize; n++) LoopUser.parse('loop-$n')!,
      ],
      suits: [for (var n = 1; n <= poolSize; n++) Suit.parse('suit-$n')!],
    ),
    // Loops read the logbook themselves for now; nothing to hand them.
    router: TrajectoryRouter(
      outcomeKinds: const {},
      proposalOf: (kind, _) => throw StateError('no outcome kinds: $kind'),
    ),
    deliver: (_, _) {},
    teamLogin: teamLogin,
    teamLoginLimit: teamLoginLimit,
    machine: SystemdUnits(),
    say: (line) => stdout.writeln(line),
  );
  stderr.writeln('loop_launcher: the logbook stream ended');
  exit(1);
}
