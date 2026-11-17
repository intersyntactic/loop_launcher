import 'dart:typed_data';

import 'package:is_logbook/is_logbook.dart' show EntryHash;
import 'package:is_logbook/service.dart' show Kind;
import 'package:is_logbook_client/is_logbook_client.dart' show Entry;
import 'package:is_shapes/is_shapes.dart' show TrajectoryId;

/// Sorts the logbook's entries by trajectory, so each loop is handed its own
/// and no other's. An entry is a trajectory's when it is on the chain from
/// the trajectory's root, or is an airlock outcome for a proposal that is.
final class TrajectoryRouter {
  /// [proposalOf] throws on a body it can't read, rather than skip it.
  TrajectoryRouter({required this._outcomeKinds, required this._proposalOf});

  final Set<Kind> _outcomeKinds;
  final EntryHash Function(Kind kind, Uint8List body) _proposalOf;

  final _trajectoryOf = <EntryHash, TrajectoryId>{};
  final _history = <TrajectoryId, List<Entry>>{};

  void rooted(TrajectoryId trajectory, EntryHash root) {
    _trajectoryOf[root] = trajectory;
    _history.putIfAbsent(trajectory, () => []);
  }

  /// The trajectory [entry] is for, kept in its history; null if none.
  TrajectoryId? route(Entry entry) {
    final outcome = switch (entry.kind) {
      final kind? when _outcomeKinds.contains(kind) => kind,
      _ => null,
    };
    final trajectory = outcome != null
        ? _trajectoryOf[_proposalOf(outcome, entry.body)]
        : switch (entry.previous) {
            final previous? => _trajectoryOf[previous],
            null => null,
          };
    if (trajectory == null) return null;
    if (outcome == null) _trajectoryOf[entry.hash] = trajectory;
    _history[trajectory]!.add(entry);
    return trajectory;
  }

  List<Entry> history(TrajectoryId trajectory) =>
      List.unmodifiable(_history[trajectory] ?? const []);

  void ended(TrajectoryId trajectory) {
    _trajectoryOf.removeWhere((_, t) => t == trajectory);
    _history.remove(trajectory);
  }
}
