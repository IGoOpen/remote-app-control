import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:remote_app_control/viewer.dart';

void main() => runApp(const ViewerApp());

class ViewerApp extends StatelessWidget {
  const ViewerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Remote App Viewer',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorSchemeSeed: Colors.indigo, useMaterial3: true),
      darkTheme: ThemeData(colorSchemeSeed: Colors.indigo, brightness: Brightness.dark, useMaterial3: true),
      home: const ViewerPage(),
    );
  }
}

class ViewerPage extends StatefulWidget {
  const ViewerPage({super.key});

  @override
  State<ViewerPage> createState() => _ViewerPageState();
}

class _ViewerPageState extends State<ViewerPage> {
  final RemoteViewerController _controller = RemoteViewerController();
  late final TextEditingController _server = TextEditingController(text: _defaultServer());
  late final TextEditingController _code = TextEditingController(text: Uri.base.queryParameters['code'] ?? '');

  /// When served by the relay, the viewer talks to the server it came from.
  static String _defaultServer() {
    if (kIsWeb && (Uri.base.scheme == 'http' || Uri.base.scheme == 'https')) {
      final scheme = Uri.base.scheme == 'https' ? 'wss' : 'ws';
      return '$scheme://${Uri.base.authority}';
    }
    return 'ws://localhost:8080';
  }

  @override
  void initState() {
    super.initState();
    if (_code.text.isNotEmpty) _connect();
  }

  @override
  void dispose() {
    _controller.dispose();
    _server.dispose();
    _code.dispose();
    super.dispose();
  }

  void _connect() {
    final server = Uri.tryParse(_server.text.trim());
    final code = _code.text.trim();
    if (server == null || code.isEmpty) return;
    _controller.connect(server: server, code: code);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _controller,
      builder: (context, _) {
        final status = _controller.status;
        final inSession = status == RemoteViewerStatus.connected || status == RemoteViewerStatus.waitingForDevice;
        return Scaffold(
          appBar: AppBar(
            title: const Text('Remote App Viewer'),
            actions: [
              if (inSession) ...[
                _StatusChip(controller: _controller),
                IconButton(
                  tooltip: 'Back (Esc)',
                  icon: const Icon(Icons.arrow_back),
                  onPressed: status == RemoteViewerStatus.connected ? () => _controller.sendKey(RemoteKey.back) : null,
                ),
                IconButton(tooltip: 'Disconnect', icon: const Icon(Icons.link_off), onPressed: _controller.disconnect),
                const SizedBox(width: 8),
              ],
            ],
          ),
          body: inSession ? _SessionView(controller: _controller) : _connectForm(context),
        );
      },
    );
  }

  Widget _connectForm(BuildContext context) {
    final theme = Theme.of(context);
    final status = _controller.status;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 380),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('Join a session', style: theme.textTheme.headlineSmall),
              const SizedBox(height: 8),
              Text('Ask the user for the support code shown in their app.', style: theme.textTheme.bodyMedium),
              const SizedBox(height: 24),
              TextField(
                controller: _code,
                autofocus: true,
                decoration: const InputDecoration(labelText: 'Support code', border: OutlineInputBorder()),
                style: const TextStyle(fontSize: 22, letterSpacing: 6),
                keyboardType: TextInputType.number,
                onSubmitted: (_) => _connect(),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _server,
                decoration: const InputDecoration(labelText: 'Server', border: OutlineInputBorder()),
                onSubmitted: (_) => _connect(),
              ),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: status == RemoteViewerStatus.connecting ? null : _connect,
                child: Text(status == RemoteViewerStatus.connecting ? 'Connecting…' : 'Connect'),
              ),
              if (status == RemoteViewerStatus.disconnected && _controller.error != null) ...[
                const SizedBox(height: 16),
                Text(_controller.error!, style: TextStyle(color: theme.colorScheme.error)),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.controller});

  final RemoteViewerController controller;

  @override
  Widget build(BuildContext context) {
    final connected = controller.status == RemoteViewerStatus.connected;
    final platform = controller.deviceInfo['platform'];
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: Chip(
        avatar: Icon(Icons.circle, size: 12, color: connected ? Colors.green : Colors.orange),
        label: Text(connected ? 'Live${platform != null ? ' · $platform' : ''}' : 'Waiting for app…'),
      ),
    );
  }
}

class _SessionView extends StatelessWidget {
  const _SessionView({required this.controller});

  final RemoteViewerController controller;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final screen = Container(
      color: theme.colorScheme.surfaceContainerHighest,
      padding: const EdgeInsets.all(16),
      child: controller.frame == null
          ? const Center(child: CircularProgressIndicator())
          : RemoteScreen(controller: controller),
    );
    final logs = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 4, 0),
          child: Row(
            children: [
              Text('Logs', style: theme.textTheme.titleSmall),
              const Spacer(),
              IconButton(
                tooltip: 'Clear',
                icon: const Icon(Icons.delete_sweep_outlined, size: 20),
                onPressed: controller.clearLogs,
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(child: RemoteLogView(controller: controller)),
      ],
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth < 800) {
          return Column(
            children: [
              Expanded(flex: 3, child: screen),
              Expanded(flex: 2, child: logs),
            ],
          );
        }
        return Row(
          children: [
            Expanded(flex: 3, child: screen),
            const VerticalDivider(width: 1),
            SizedBox(width: 420, child: logs),
          ],
        );
      },
    );
  }
}
