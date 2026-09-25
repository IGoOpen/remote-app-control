import 'package:flutter/material.dart';

import 'remote_viewer_controller.dart';

/// A scrolling console of the remote app's logs and errors.
class RemoteLogView extends StatefulWidget {
  const RemoteLogView({super.key, required this.controller});

  final RemoteViewerController controller;

  @override
  State<RemoteLogView> createState() => _RemoteLogViewState();
}

class _RemoteLogViewState extends State<RemoteLogView> {
  final ScrollController _scroll = ScrollController();
  bool _follow = true;

  @override
  void initState() {
    super.initState();
    widget.controller.logRevision.addListener(_onLogs);
    _scroll.addListener(() {
      if (!_scroll.hasClients) return;
      _follow = _scroll.position.extentAfter < 24;
    });
  }

  @override
  void dispose() {
    widget.controller.logRevision.removeListener(_onLogs);
    _scroll.dispose();
    super.dispose();
  }

  void _onLogs() {
    setState(() {});
    if (!_follow) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) _scroll.jumpTo(_scroll.position.maxScrollExtent);
    });
  }

  @override
  Widget build(BuildContext context) {
    final logs = widget.controller.logs;
    final theme = Theme.of(context);
    if (logs.isEmpty) {
      return Center(child: Text('No logs yet', style: theme.textTheme.bodySmall));
    }
    return SelectionArea(
      child: ListView.builder(
        controller: _scroll,
        padding: const EdgeInsets.all(8),
        itemCount: logs.length,
        itemBuilder: (context, index) {
          final log = logs[index];
          final time = log.time.toIso8601String().substring(11, 23);
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Text(
              '$time  ${log.message}',
              style: TextStyle(
                fontFamily: 'monospace',
                fontSize: 12,
                color: log.isError ? theme.colorScheme.error : theme.colorScheme.onSurface,
              ),
            ),
          );
        },
      ),
    );
  }
}
