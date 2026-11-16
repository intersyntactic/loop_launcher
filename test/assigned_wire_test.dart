// A wire contract: the `assigned` entry's bytes, as other services read
// them from the record.
import 'dart:convert';
import 'dart:typed_data';

import 'package:is_airlock_api/is_airlock_api.dart' show JourneyUser, LoopUser;
import 'package:is_loop_launcher/is_loop_launcher.dart';
import 'package:is_shapes/is_shapes.dart';
import 'package:test/test.dart';

void main() {
  final path = 'a1' * 32;
  final journey = 'b2' * 32;
  final bytes =
      '{"journeyPath":"$path","journey":"$journey",'
      '"loopUser":"loop-3","journeyUser":"journey-12"}';

  test('assigned is these bytes, and reads back', () {
    final a = Assigned(
      journeyPath: JourneyPathId.parse(path)!,
      journey: JourneyId.parse(journey)!,
      loopUser: LoopUser.parse('loop-3')!,
      journeyUser: JourneyUser.parse('journey-12')!,
    );
    expect(utf8.decode(a.encode()), bytes);
    expect(Assigned.kind.toString(), 'assigned');
    expect(Assigned.decode(a.encode())?.journeyUser.name, 'journey-12');
  });

  test('assigned is read strictly', () {
    Assigned? read(String s) =>
        Assigned.decode(Uint8List.fromList(utf8.encode(s)));
    expect(read(bytes.replaceFirst('}', ',"extra":1}')), isNull);
    expect(read(bytes.replaceFirst('loop-3', 'loop-03')), isNull);
    expect(read(bytes.replaceFirst('journey-12', 'loop-12')), isNull);
  });
}
