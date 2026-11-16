/// The two pools, and which journey paths hold which of their users.
library;

import 'dart:collection';

import 'package:is_journal/is_journal.dart' show EntryHash;
import 'package:is_shapes/is_shapes.dart' show JourneyId, JourneyPathId;

import 'assigned.dart';
import 'pool_user.dart';

/// The loop users and journey users made for loop_launcher, and who holds
/// each. A journey holds one journey user for all its paths; each path holds
/// a loop user of its own. Rebuilt from the record's `assigned` entries on
/// every start, so it is never stored anywhere else.
final class Pools {
  Pools({
    required Iterable<LoopUser> loopUsers,
    required Iterable<JourneyUser> journeyUsers,
  }) : _freeLoops = SplayTreeSet.of(loopUsers, (a, b) => a.n.compareTo(b.n)),
       _freeJourneys = SplayTreeSet.of(
         journeyUsers,
         (a, b) => a.n.compareTo(b.n),
       );

  final SplayTreeSet<LoopUser> _freeLoops;
  final SplayTreeSet<JourneyUser> _freeJourneys;
  final _journeyUsers = <JourneyId, JourneyUser>{};
  final _paths = <JourneyPathId, Held>{};

  /// What [path] was handed, if it has been.
  Held? of(JourneyPathId path) => _paths[path];

  /// Every path handed users and not yet ended, in the order they were.
  Iterable<Held> get live => _paths.values;

  /// Takes [assigned], recorded at [root], as held.
  void take(Assigned assigned, EntryHash root) {
    _freeLoops.remove(assigned.loopUser);
    _freeJourneys.remove(assigned.journeyUser);
    _journeyUsers[assigned.journey] = assigned.journeyUser;
    _paths[assigned.journeyPath] = Held(assigned, root);
  }

  /// The users [path], in [journey], would be handed: the journey's own
  /// journey user if it has one, else a free one, which has to be wiped
  /// before it is handed out; and a free loop user. Takes nothing: the
  /// handout is held once its `assigned` entry is recorded and [take]n.
  Handout handout(JourneyPathId path, JourneyId journey) {
    final loop = _freeLoops.firstOrNull;
    if (loop == null) return const Exhausted('no loop user is free');
    if (_journeyUsers[journey] case final held?) {
      return Free(
        Assigned(
          journeyPath: path,
          journey: journey,
          loopUser: loop,
          journeyUser: held,
        ),
        wipeFirst: false,
      );
    }
    return switch (_freeJourneys.firstOrNull) {
      final user? => Free(
        Assigned(
          journeyPath: path,
          journey: journey,
          loopUser: loop,
          journeyUser: user,
        ),
        wipeFirst: true,
      ),
      null => const Exhausted('no journey user is free'),
    };
  }

  /// [journey] has ended: its journey user and its paths' loop users are
  /// free again.
  void ended(JourneyId journey) {
    if (_journeyUsers.remove(journey) case final user?) _freeJourneys.add(user);
    _paths.removeWhere((_, held) {
      if (held.assigned.journey != journey) return false;
      _freeLoops.add(held.assigned.loopUser);
      return true;
    });
  }
}

/// A path's [assigned] users, recorded at [root]: the `assigned` entry that
/// roots the path's chain, which its loop's first turn follows.
final class Held {
  const Held(this.assigned, this.root);

  final Assigned assigned;
  final EntryHash root;
}

/// What [Pools.handout] gives: [Free] users, or [Exhausted].
sealed class Handout {
  const Handout();
}

/// [assigned] can be handed out. [wipeFirst] when its journey user is new
/// to the journey: its home is emptied before anything else is done.
final class Free extends Handout {
  const Free(this.assigned, {required this.wipeFirst});

  final Assigned assigned;
  final bool wipeFirst;
}

/// A pool has no user free; [why] says which.
final class Exhausted extends Handout {
  const Exhausted(this.why);

  final String why;
}
