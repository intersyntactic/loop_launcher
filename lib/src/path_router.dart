/// Which journey path's loop an entry in the record goes to, if any (Nick,
/// 16 Nov: "1", of what an effect returns being in the record, once).
library;

import 'dart:typed_data';

import 'package:is_journal/is_journal.dart' show EntryHash;
import 'package:is_journal/service.dart' show Kind;
import 'package:is_journal_client/is_journal_client.dart' show Entry;
import 'package:is_shapes/is_shapes.dart' show JourneyPathId;

/// Sorts the record's entries by journey path, so each path's loop is
/// handed its own and no other's: the journal can't tell which path an
/// entry is about, and a loop that read the record itself could read
/// another conversation.
///
/// An entry is a path's when it is on the path's chain, which starts at its
/// `assigned` entry and runs through each entry's `previous`; the journal
/// refuses one whose `previous` is not its chain's tip, so the chain is one
/// line. The airlock's outcomes are on chains of their own, so one is a
/// path's when the proposal it names is on the path's chain.
final class PathRouter {
  /// [outcomeKinds] are the airlock's entries that answer a proposal, and
  /// [proposalOf] reads which proposal one answers. [proposalOf] throws on
  /// a body it can't read: it is our own wire, read strictly, and an
  /// outcome skipped would leave its loop waiting, unsaid.
  PathRouter({required this._outcomeKinds, required this._proposalOf});

  final Set<Kind> _outcomeKinds;
  final EntryHash Function(Kind kind, Uint8List body) _proposalOf;

  /// The path each entry on a live path's chain is on, its root included.
  final _pathOf = <EntryHash, JourneyPathId>{};

  /// Each live path's entries, after its root, in the record's order.
  final _history = <JourneyPathId, List<Entry>>{};

  /// [path]'s chain starts at [root], its `assigned` entry.
  void rooted(JourneyPathId path, EntryHash root) {
    _pathOf[root] = path;
    _history.putIfAbsent(path, () => []);
  }

  /// The live path [entry] is for, kept in its history; null if it is on
  /// no live path's chain, nor answers a proposal that is.
  JourneyPathId? route(Entry entry) {
    final outcome = switch (entry.kind) {
      final kind? when _outcomeKinds.contains(kind) => kind,
      _ => null,
    };
    final path = outcome != null
        ? _pathOf[_proposalOf(outcome, entry.body)]
        : switch (entry.previous) {
            final previous? => _pathOf[previous],
            null => null,
          };
    if (path == null) return null;
    if (outcome == null) _pathOf[entry.hash] = path;
    _history[path]!.add(entry);
    return path;
  }

  /// [path]'s entries so far, after its root, in the record's order: what
  /// its loop is handed when it starts, before the live ones.
  List<Entry> history(JourneyPathId path) =>
      List.unmodifiable(_history[path] ?? const []);

  /// [path]'s journey has ended, and its chain is closed.
  void ended(JourneyPathId path) {
    _pathOf.removeWhere((_, p) => p == path);
    _history.remove(path);
  }
}
