// Reads `<index>\t<body>` lines on stdin, each body one
// users-assigned-to-trajectory entry, and checks it with the decoder `run`
// replays them with. Prints `<index>\tunreadable: <reason>` for each body
// refused, then `ok <n>`; exits 1 if any were refused.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:checked_json/checked_json.dart'
    show decodeJsonRefusingDuplicateKeysAndUnsafeIntegers;
import 'package:is_loop_launcher/is_loop_launcher.dart';

Future<void> main() async {
  var read = 0;
  var refused = 0;
  await for (final line
      in stdin.transform(utf8.decoder).transform(const LineSplitter())) {
    if (line.isEmpty) continue;
    read++;
    final tab = line.indexOf('\t');
    if (tab < 0) {
      refused++;
      stdout.writeln('line $read\tunreadable: no tab after the index');
      continue;
    }
    final index = line.substring(0, tab);
    final body = line.substring(tab + 1);
    if (UsersAssignedToTrajectory.decode(
          Uint8List.fromList(utf8.encode(body)),
        ) ==
        null) {
      refused++;
      stdout.writeln('$index\tunreadable: ${_why(body)}');
    }
  }
  stdout.writeln('ok $read');
  exitCode = refused == 0 ? 0 : 1;
}

String _why(String body) {
  try {
    decodeJsonRefusingDuplicateKeysAndUnsafeIntegers(body);
  } on FormatException catch (e) {
    return e.message;
  }
  return 'not exactly the four string fields trajectory, mission, '
      'loopUser (loop-<n>) and suit (suit-<n>)';
}
