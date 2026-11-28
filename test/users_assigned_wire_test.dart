// A wire contract: the users-assigned entry's bytes, as the logbook and the
// airlock read them.
import 'dart:convert';
import 'dart:typed_data';

import 'package:is_airlock_api/is_airlock_api.dart' show LoopUser, Suit;
import 'package:is_loop_launcher/is_loop_launcher.dart';
import 'package:is_shapes/is_shapes.dart';
import 'package:test/test.dart';

void main() {
  final trajectory = 'a1' * 32;
  final mission = 'b2' * 32;
  final bytes =
      '{"trajectory":"$trajectory","mission":"$mission",'
      '"loopUser":"loop-3","suit":"suit-12"}';

  test('users-assigned-to-trajectory is these bytes, and reads back', () {
    final users = UsersAssignedToTrajectory(
      trajectory: TrajectoryId.parse(trajectory)!,
      mission: MissionId.parse(mission)!,
      loopUser: LoopUser.parse('loop-3')!,
      suit: Suit.parse('suit-12')!,
    );
    expect(utf8.decode(users.encode()), bytes);
    expect(
      UsersAssignedToTrajectory.kind.toString(),
      'users-assigned-to-trajectory',
    );
    expect(
      UsersAssignedToTrajectory.decode(users.encode())?.suit.name,
      'suit-12',
    );
  });

  test('it is read strictly', () {
    UsersAssignedToTrajectory? read(String s) =>
        UsersAssignedToTrajectory.decode(Uint8List.fromList(utf8.encode(s)));
    expect(read(bytes.replaceFirst('}', ',"extra":1}')), isNull);
    expect(read(bytes.replaceFirst('loop-3', 'loop-03')), isNull);
    expect(read(bytes.replaceFirst('suit-12', 'loop-12')), isNull);
    expect(read(bytes.replaceFirst('"trajectory"', '"journeyPath"')), isNull);
    expect(read(bytes.replaceFirst('"mission"', '"journey"')), isNull);
  });

  test('a body naming a key twice is refused, not read as its last', () {
    UsersAssignedToTrajectory? read(String s) =>
        UsersAssignedToTrajectory.decode(Uint8List.fromList(utf8.encode(s)));
    final twice =
        '{"trajectory":"$trajectory","mission":"$mission",'
        '"loopUser":"loop-3","loopUser":"loop-4","suit":"suit-12"}';
    expect(read(twice), isNull);
  });
}
