import 'dart:typed_data';

import 'package:is_logbook_client/is_logbook_client.dart'
    show Entry, Kind, ObjectId;
import 'package:is_shapes/is_shapes.dart' show TrajectoryId;

/// Sorts the logbook's entries by trajectory, so each loop is handed its own
/// and no other's: each admission that started it or was placed on it, its
/// root, the entries on its chain, and the airlock's outcomes for its
/// proposals. A relayed event, the bytes a stranger sent, is handed to no
/// loop: its admission carries what was made of it.
final class TrajectoryRouter {
  /// [proposalOf] names the proposal an outcome answers; null when the entry
  /// answers no proposal.
  TrajectoryRouter({required this._outcomeKinds, required this._proposalOf});

  final Set<Kind> _outcomeKinds;
  final ObjectId? Function(Kind kind, Uint8List body) _proposalOf;

  final _trajectoryOf = <ObjectId, TrajectoryId>{};
  final _history = <TrajectoryId, List<Entry>>{};

  /// [admitted] started [trajectory].
  void started(TrajectoryId trajectory, Entry admitted) {
    _history.putIfAbsent(trajectory, () => []).add(admitted);
  }

  /// [trajectory]'s chain starts at [root], its users-assigned entry.
  void rooted(TrajectoryId trajectory, Entry root) {
    _trajectoryOf[root.id] = trajectory;
    _history.putIfAbsent(trajectory, () => []).add(root);
  }

  /// [admitted] was placed on [trajectory]; false if it isn't live.
  bool placed(TrajectoryId trajectory, Entry admitted) {
    final history = _history[trajectory];
    if (history == null) return false;
    history.add(admitted);
    return true;
  }

  /// The trajectory [entry] is for, kept in its history; null if none.
  TrajectoryId? route(Entry entry) {
    final isOutcome = _outcomeKinds.contains(entry.kind);
    final trajectory = isOutcome
        ? switch (_proposalOf(entry.kind, entry.body)) {
            final proposal? => _trajectoryOf[proposal],
            null => null,
          }
        : switch (entry.previous) {
            final previous? => _trajectoryOf[previous],
            null => null,
          };
    if (trajectory == null) return null;
    if (!isOutcome) _trajectoryOf[entry.id] = trajectory;
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
