import 'dart:typed_data';

import 'package:is_logbook/is_logbook.dart' show EntryHash;
import 'package:is_logbook/service.dart' show Kind;
import 'package:is_logbook_client/is_logbook_client.dart' show Entry;
import 'package:is_shapes/is_shapes.dart' show EntryId, TrajectoryId;

/// Sorts the logbook's entries by trajectory, so each loop is handed its own
/// and no other's: the admission that started it, its root, the entries on
/// its chain, later admissions placed on it, and the airlock's outcomes for
/// its proposals.
final class TrajectoryRouter {
  /// [proposalOf] names the proposal an outcome answers, by the EntryId of
  /// the proposal's bytes; null when the entry answers no proposal.
  TrajectoryRouter({required this._outcomeKinds, required this._proposalOf});

  final Set<Kind> _outcomeKinds;
  final EntryId? Function(Kind kind, Uint8List body) _proposalOf;

  // A chain links by EntryHash; an outcome names its proposal by EntryId.
  final _trajectoryOf = <EntryHash, TrajectoryId>{};
  final _trajectoryOfProposal = <EntryId, TrajectoryId>{};
  final _history = <TrajectoryId, List<Entry>>{};

  /// [admitted] started [trajectory].
  void started(TrajectoryId trajectory, Entry admitted) {
    _history.putIfAbsent(trajectory, () => []).add(admitted);
  }

  /// [trajectory]'s chain starts at [root], its users-assigned entry.
  void rooted(TrajectoryId trajectory, Entry root) {
    _trajectoryOf[root.hash] = trajectory;
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
    final outcome = switch (entry.kind) {
      final kind? when _outcomeKinds.contains(kind) => kind,
      _ => null,
    };
    final trajectory = outcome != null
        ? switch (_proposalOf(outcome, entry.body)) {
            final proposal? => _trajectoryOfProposal[proposal],
            null => null,
          }
        : switch (entry.previous) {
            final previous? => _trajectoryOf[previous],
            null => null,
          };
    if (trajectory == null) return null;
    if (outcome == null) {
      _trajectoryOf[entry.hash] = trajectory;
      _trajectoryOfProposal[EntryId.of(entry.recorded)] = trajectory;
    }
    _history[trajectory]!.add(entry);
    return trajectory;
  }

  List<Entry> history(TrajectoryId trajectory) =>
      List.unmodifiable(_history[trajectory] ?? const []);

  void ended(TrajectoryId trajectory) {
    _trajectoryOf.removeWhere((_, t) => t == trajectory);
    _trajectoryOfProposal.removeWhere((_, t) => t == trajectory);
    _history.remove(trajectory);
  }
}
