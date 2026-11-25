import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:is_airlock_api/is_airlock_api.dart' show LoopUser;
import 'package:is_logbook_client/is_logbook_client.dart' show Entry, Kind;
import 'package:is_shapes/is_shapes.dart' show TrajectoryId;

import 'trajectory_router.dart';

/// Each loop's only way into the logbook: a socket at
/// `<dir>/<loop user>/feed.sock` that answers the logbook's `subscribe`
/// with the entries of the trajectory that loop user holds, and no other's.
/// The directory's group is the loop user's, so only it can connect.
final class LoopFeeds {
  LoopFeeds({
    required this._dir,
    required this._router,
    required this._trajectoryOf,
  });

  final String _dir;
  final TrajectoryRouter _router;
  final TrajectoryId? Function(LoopUser user) _trajectoryOf;
  final _listening = <TrajectoryId, List<(Set<Kind>?, Socket)>>{};

  String pathOf(LoopUser user) => '$_dir/$user/feed.sock';

  Future<void> bind(Iterable<LoopUser> users) async {
    for (final user in users) {
      final path = pathOf(user);
      // A socket left by the last run would make the bind fail.
      await Process.run('rm', ['-f', path]);
      final server = await ServerSocket.bind(
        InternetAddress(path, type: InternetAddressType.unix),
        0,
      );
      final chmod = await Process.run('chmod', ['0660', path]);
      if (chmod.exitCode != 0) {
        throw StateError('chmod $path: ${chmod.stderr}');
      }
      server.listen((socket) => _serve(user, socket));
    }
  }

  /// Hands [entry], live, to whoever follows [trajectory].
  void deliver(TrajectoryId trajectory, Entry entry) {
    for (final (kinds, socket)
        in _listening[trajectory] ?? const <(Set<Kind>?, Socket)>[]) {
      if (kinds == null || kinds.contains(entry.kind)) _send(socket, entry);
    }
  }

  void _serve(LoopUser user, Socket socket) {
    final line = BytesBuilder();
    var answered = false;
    socket.listen(
      (bytes) {
        if (answered) return;
        final newline = bytes.indexOf(0x0a);
        if (newline < 0) {
          line.add(bytes);
          return;
        }
        line.add(bytes.sublist(0, newline));
        answered = true;
        _answer(
          user,
          socket,
          ascii.decode(line.takeBytes(), allowInvalid: true),
        );
      },
      onDone: () => _drop(socket),
      onError: (Object _) => _drop(socket),
    );
  }

  void _answer(LoopUser user, Socket socket, String request) {
    final Set<Kind>? kinds;
    switch (request.split(' ')) {
      case ['subscribe', '*', 'from', 'start']:
        kinds = null;
      case ['subscribe', final names, 'from', 'start']:
        final parsed = names.split(',').map(Kind.parse).toList();
        if (parsed.contains(null)) return _refuse(socket, 'kinds');
        kinds = {for (final kind in parsed) kind!};
      case ['subscribe', _, 'from', _]:
        return _refuse(socket, 'only from start');
      default:
        return _refuse(socket, 'only subscribe');
    }
    final trajectory = _trajectoryOf(user);
    if (trajectory == null) return _refuse(socket, 'no trajectory');
    final history = _router.history(trajectory);
    for (final entry in history) {
      if (kinds == null || kinds.contains(entry.kind)) _send(socket, entry);
    }
    socket.add(
      ascii.encode('caught-up ${history.lastOrNull?.id.hex ?? 'start'}\n'),
    );
    _listening.putIfAbsent(trajectory, () => []).add((kinds, socket));
  }

  void _refuse(Socket socket, String why) {
    socket.add(ascii.encode('refused $why\n'));
    socket.destroy();
  }

  void _send(Socket socket, Entry entry) {
    socket
      ..add(
        ascii.encode(
          'entry ${entry.id.hex} ${entry.kind.name} '
          '${entry.previous?.hex ?? '-'} ${entry.recorded.length} '
          '${entry.trajectory?.hex ?? '-'}\n',
        ),
      )
      ..add(entry.recorded);
  }

  void _drop(Socket socket) {
    for (final listeners in _listening.values) {
      listeners.removeWhere((l) => l.$2 == socket);
    }
    socket.destroy();
  }
}
