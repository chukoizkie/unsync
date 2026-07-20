import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../theme.dart';
import '../models/call_log_entry.dart';
import '../services/call_log_store.dart';

/// Full-page call log with filtering. Read-only view over CallLogStore.
///
/// Reached by long-pressing the "Calls" tab on the contacts screen. Displays
/// entries most-recent-first, filterable by All / Missed / Incoming / Outgoing.
/// peerId and callId are stored but NEVER shown — only the display name.
class CallLogScreen extends StatefulWidget {
  const CallLogScreen({super.key, this.store});

  /// Injectable for testing; defaults to a real CallLogStore in initState.
  final CallLogStore? store;

  @override
  State<CallLogScreen> createState() => _CallLogScreenState();
}

enum _Filter { all, missed, incoming, outgoing }

extension _FilterLabel on _Filter {
  String get label {
    switch (this) {
      case _Filter.all:
        return 'All';
      case _Filter.missed:
        return 'Missed';
      case _Filter.incoming:
        return 'Incoming';
      case _Filter.outgoing:
        return 'Outgoing';
    }
  }
}

class _CallLogScreenState extends State<CallLogScreen> {
  late final CallLogStore _store;
  _Filter _filter = _Filter.all;
  bool _loading = true;
  List<CallLogEntry> _all = const [];

  @override
  void initState() {
    super.initState();
    _store = widget.store ?? CallLogStore();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    var entries = await _store.load();

    // Debug-only: if the log is empty, show sample rows so the page can be
    // seen working before any real call has been placed. Never runs in release.
    if (kDebugMode && entries.isEmpty) {
      entries = _sampleEntries();
    }

    if (!mounted) return;
    setState(() {
      _all = entries;
      _loading = false;
    });
  }

  List<CallLogEntry> get _filtered {
    switch (_filter) {
      case _Filter.all:
        return _all;
      case _Filter.missed:
        return _all.where((e) => e.isMissedCall).toList(growable: false);
      case _Filter.incoming:
        return _all
            .where((e) => e.direction == CallDirection.incoming)
            .toList(growable: false);
      case _Filter.outgoing:
        return _all
            .where((e) => e.direction == CallDirection.outgoing)
            .toList(growable: false);
    }
  }

  Future<void> _confirmClear() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: kBg,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.zero,
          side: BorderSide(color: kBorder),
        ),
        title: const Text('Clear call log', style: TextStyle(color: kText)),
        content: const Text(
          'This deletes every entry from this device. It cannot be undone.',
          style: TextStyle(color: kMuted, fontSize: 13),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel', style: TextStyle(color: kMuted)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Clear', style: TextStyle(color: Color(0xFFFF6B6B))),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await _store.clear();
      await _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kBg,
      appBar: AppBar(
        backgroundColor: kBg,
        elevation: 0,
        iconTheme: const IconThemeData(color: kMuted),
        title: const Text(
          'Call log',
          style: TextStyle(
            color: kText,
            fontSize: 16,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.5,
          ),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.delete_outline, color: kMuted),
            tooltip: 'Clear call log',
            onPressed: _all.isEmpty ? null : _confirmClear,
          ),
          const SizedBox(width: 4),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(1),
          child: Container(height: 1, color: kBorder),
        ),
      ),
      body: Column(
        children: [
          _buildFilterRow(),
          Container(height: 1, color: kBorder),
          Expanded(child: _buildList()),
        ],
      ),
    );
  }

  Widget _buildFilterRow() {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      child: Row(
        children: _Filter.values.map((f) {
          final selected = _filter == f;
          return Padding(
            padding: const EdgeInsets.only(right: 8),
            child: GestureDetector(
              onTap: () => setState(() => _filter = f),
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                decoration: BoxDecoration(
                  color: selected ? kAccentDim : Colors.transparent,
                  border: Border.all(color: selected ? kAccent : kBorder),
                ),
                child: Text(
                  f.label,
                  style: TextStyle(
                    color: selected ? kAccent : kMuted,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.5,
                  ),
                ),
              ),
            ),
          );
        }).toList(growable: false),
      ),
    );
  }

  Widget _buildList() {
    if (_loading) {
      return const Center(
        child: SizedBox(
          width: 20,
          height: 20,
          child: CircularProgressIndicator(strokeWidth: 2, color: kAccent),
        ),
      );
    }

    final items = _filtered;
    if (items.isEmpty) {
      return Center(
        child: Text(
          _emptyLabel,
          style: const TextStyle(color: kMuted, fontSize: 13),
        ),
      );
    }

    return ListView.separated(
      itemCount: items.length,
      separatorBuilder: (_, __) => Container(height: 1, color: kBorder),
      itemBuilder: (context, i) => _CallLogRow(entry: items[i]),
    );
  }

  String get _emptyLabel {
    switch (_filter) {
      case _Filter.all:
        return 'No calls yet';
      case _Filter.missed:
        return 'No missed calls';
      case _Filter.incoming:
        return 'No incoming calls';
      case _Filter.outgoing:
        return 'No outgoing calls';
    }
  }

  List<CallLogEntry> _sampleEntries() {
    final now = DateTime.now();
    return [
      CallLogEntry(
        peerId: 'sample-1',
        name: 'Alex Rivera',
        direction: CallDirection.incoming,
        outcome: CallOutcome.missed,
        type: CallType.video,
        timestamp: now.subtract(const Duration(minutes: 12)),
        callId: 'sample-call-1',
      ),
      CallLogEntry(
        peerId: 'sample-2',
        name: 'Jordan Lee',
        direction: CallDirection.incoming,
        outcome: CallOutcome.answered,
        type: CallType.audio,
        timestamp: now.subtract(const Duration(hours: 2)),
        callId: 'sample-call-2',
        duration: const Duration(minutes: 4, seconds: 12),
      ),
      CallLogEntry(
        peerId: 'sample-3',
        name: 'Sam Okafor',
        direction: CallDirection.outgoing,
        outcome: CallOutcome.answered,
        type: CallType.audio,
        timestamp: now.subtract(const Duration(hours: 5)),
        callId: 'sample-call-3',
        duration: const Duration(seconds: 47),
      ),
      CallLogEntry(
        peerId: 'sample-4',
        name: 'Priya Nair',
        direction: CallDirection.incoming,
        outcome: CallOutcome.declined,
        type: CallType.audio,
        timestamp: now.subtract(const Duration(days: 1, hours: 3)),
        callId: 'sample-call-4',
      ),
    ];
  }
}

class _CallLogRow extends StatelessWidget {
  const _CallLogRow({required this.entry});

  final CallLogEntry entry;

  static const _missedColor = Color(0xFFFF6B6B);

  bool get _isMissed => entry.isMissedCall;

  @override
  Widget build(BuildContext context) {
    final missed = _isMissed;
    final iconColor = missed ? _missedColor : kAccent;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          Icon(_directionIcon, size: 18, color: iconColor),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  entry.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: missed ? _missedColor : kText,
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  _subtitle,
                  style: const TextStyle(color: kMuted, fontSize: 11),
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          Icon(
            entry.type == CallType.video ? Icons.videocam : Icons.call,
            size: 15,
            color: kMuted,
          ),
        ],
      ),
    );
  }

  IconData get _directionIcon {
    if (_isMissed) return Icons.call_missed;
    if (entry.direction == CallDirection.outgoing) return Icons.call_made;
    return Icons.call_received;
  }

  String get _subtitle {
    final parts = <String>[_outcomeLabel];
    if (entry.outcome == CallOutcome.answered && entry.duration != null) {
      parts.add(_formatDuration(entry.duration!));
    }
    parts.add(_relativeTime(entry.timestamp));
    return parts.join(' · ');
  }

  String get _outcomeLabel {
    switch (entry.outcome) {
      case CallOutcome.answered:
        return entry.direction == CallDirection.outgoing ? 'Outgoing' : 'Answered';
      case CallOutcome.missed:
        return _isMissed ? 'Missed' : 'No answer';
      case CallOutcome.declined:
        return 'Declined';
    }
  }

  static String _formatDuration(Duration d) {
    final m = d.inMinutes;
    final s = d.inSeconds % 60;
    return '$m:${s.toString().padLeft(2, '0')}';
  }

  static String _relativeTime(DateTime t) {
    final diff = DateTime.now().difference(t);
    if (diff.inMinutes < 1) return 'just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    if (diff.inDays < 7) return '${diff.inDays}d ago';
    return '${t.year}-${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')}';
  }
}
