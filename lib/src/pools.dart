/// The two pools, and which journey paths hold which of their users.
library;

import 'dart:collection';

import 'package:is_journal/is_journal.dart' show EntryHash;
import 'package:is_shapes/is_shapes.dart' show JourneyId, JourneyPathId;

import 'assigned.dart';

import 'package:is_airlock_api/is_airlock_api.dart' show LoopUser, Suit;

/// The loop users and suits made for loop_launcher, and who holds each.
/// Each path holds a loop user and a suit of its own, and no two paths
/// share either (Nick, 16 Nov: every path wears a suit). Rebuilt from the
/// record's `assigned` entries on every start, so it is never stored
/// anywhere else.
final class Pools {
  Pools({required Iterable<LoopUser> loopUsers, required Iterable<Suit> suits})
    : _freeLoops = SplayTreeSet.of(loopUsers, (a, b) => a.n.compareTo(b.n)),
      _freeSuits = SplayTreeSet.of(suits, (a, b) => a.n.compareTo(b.n));

  final SplayTreeSet<LoopUser> _freeLoops;
  final SplayTreeSet<Suit> _freeSuits;
  final _paths = <JourneyPathId, Handed>{};

  /// What [path] was handed, if it has been.
  Handed? of(JourneyPathId path) => _paths[path];

  /// Every path handed users and not yet ended, in the order they were.
  Iterable<Handed> get live => _paths.values;

  /// Takes [assigned], recorded at [root], as handed out.
  void take(Assigned assigned, EntryHash root) {
    _freeLoops.remove(assigned.loopUser);
    _freeSuits.remove(assigned.suit);
    _paths[assigned.journeyPath] = Handed(assigned, root);
  }

  /// The users [path], in [journey], would be handed: a free loop user and
  /// a free suit, which has to be wiped before it is handed out. Takes
  /// nothing: the handout is taken once its `assigned` entry is recorded and
  /// [take]n.
  Handout handout(JourneyPathId path, JourneyId journey) => switch ((
    _freeLoops.firstOrNull,
    _freeSuits.firstOrNull,
  )) {
    (null, _) => const Exhausted('no loop user is free'),
    (_, null) => const Exhausted('no suit is free'),
    (final loop?, final suit?) => Free(
      Assigned(journeyPath: path, journey: journey, loopUser: loop, suit: suit),
    ),
  };

  /// [journey] has ended: its paths' loop users and suits are free again.
  void ended(JourneyId journey) {
    _paths.removeWhere((_, handed) {
      if (handed.assigned.journey != journey) return false;
      _freeLoops.add(handed.assigned.loopUser);
      _freeSuits.add(handed.assigned.suit);
      return true;
    });
  }
}

/// A path's [assigned] users, recorded at [root]: the `assigned` entry that
/// roots the path's chain, which its loop's first turn follows.
final class Handed {
  const Handed(this.assigned, this.root);

  final Assigned assigned;
  final EntryHash root;
}

/// What [Pools.handout] gives: [Free] users, or [Exhausted].
sealed class Handout {
  const Handout();
}

/// [assigned] can be handed out, once its suit's home is emptied.
final class Free extends Handout {
  const Free(this.assigned);

  final Assigned assigned;
}

/// A pool has no user free; [why] says which.
final class Exhausted extends Handout {
  const Exhausted(this.why);

  final String why;
}
