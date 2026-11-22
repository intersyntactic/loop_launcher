import 'dart:typed_data';

import 'package:is_logbook_client/is_logbook_client.dart'
    show Entry, Kind, ObjectId;
import 'package:is_shapes/is_shapes.dart' show TrajectoryId;

/// Sorts the logbook's entries by trajectory, so each loop is handed its own
/// and no other's: each admission that started it or was placed on it, just
/// after the raw event that admission names, its root, the entries on its
/// chain, and the airlock's outcomes for its proposals.
final class TrajectoryRouter {
  /// Entries of [eventKinds] are raw events, held until an admission names
  /// them. [proposalOf] names the proposal an outcome answers; null when the
  /// entry answers no proposal.
  TrajectoryRouter({
    required this._eventKinds,
    required this._outcomeKinds,
    required this._proposalOf,
  });

  final Set<Kind> _eventKinds;
  final Set<Kind> _outcomeKinds;
  final ObjectId? Function(Kind kind, Uint8List body) _proposalOf;

  final _events = <ObjectId, Entry>{};
  final _trajectoryOf = <ObjectId, TrajectoryId>{};
  final _history = <TrajectoryId, List<Entry>>{};

  /// [admitted], which admits [event], started [trajectory].
  void started(TrajectoryId trajectory, Entry admitted, ObjectId event) {
    _history
        .putIfAbsent(trajectory, () => [])
        .addAll([?_events.remove(event), admitted]);
  }

  /// [trajectory]'s chain starts at [root], its users-assigned entry.
  void rooted(TrajectoryId trajectory, Entry root) {
    _trajectoryOf[root.id] = trajectory;
    _history.putIfAbsent(trajectory, () => []).add(root);
  }

  /// [admitted], which admits [event], was placed on [trajectory]. The
  /// entries added to its history, in order; null if it isn't live.
  List<Entry>? placed(TrajectoryId trajectory, Entry admitted, ObjectId event) {
    final added = [?_events.remove(event), admitted];
    final history = _history[trajectory];
    if (history == null) return null;
    history.addAll(added);
    return added;
  }

  /// [event] was decided without starting or joining a trajectory.
  void decided(ObjectId event) => _events.remove(event);

  /// The trajectory [entry] is for, kept in its history; null if none. A
  /// raw event is held for the admission that names it, and goes nowhere yet.
  TrajectoryId? route(Entry entry) {
    if (_eventKinds.contains(entry.kind)) {
      _events[entry.id] = entry;
      return null;
    }
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
