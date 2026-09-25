import 'dart:async';
import 'dart:collection';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';

enum RemoteLogLevel { info, error }

class RemoteLogEntry {
  RemoteLogEntry(this.level, this.message) : time = DateTime.now();

  final RemoteLogLevel level;
  final String message;
  final DateTime time;

  Map<String, Object> toJson() => {'t': time.millisecondsSinceEpoch, 'l': level.name, 'm': message};
}

/// Collects `print` output and uncaught errors, keeping a bounded history so
/// a viewer that joins late still sees what happened before.
class LogCapture {
  LogCapture._();

  static final LogCapture instance = LogCapture._();

  static const int historyLimit = 500;

  final Queue<RemoteLogEntry> _history = Queue();
  final StreamController<RemoteLogEntry> _controller = StreamController.broadcast(sync: true);
  bool _errorHooksInstalled = false;

  Stream<RemoteLogEntry> get entries => _controller.stream;
  List<RemoteLogEntry> get history => List.unmodifiable(_history);

  void add(RemoteLogLevel level, String message) {
    final entry = RemoteLogEntry(level, message);
    _history.addLast(entry);
    if (_history.length > historyLimit) _history.removeFirst();
    _controller.add(entry);
  }

  /// Runs [body] in a zone whose `print` calls are also captured.
  R runZoned<R>(R Function() body) {
    installErrorHooks();
    return Zone.current
        .fork(
          specification: ZoneSpecification(
            print: (self, parent, zone, line) {
              add(RemoteLogLevel.info, line);
              parent.print(zone, line);
            },
          ),
        )
        .run(body);
  }

  /// Chains onto the framework error handlers without replacing the app's.
  void installErrorHooks() {
    if (_errorHooksInstalled) return;
    _errorHooksInstalled = true;

    final previousFlutterError = FlutterError.onError;
    FlutterError.onError = (details) {
      // `details.toString()` is only descriptive in debug builds.
      add(RemoteLogLevel.error, '${details.exceptionAsString()}\n${details.stack ?? ''}'.trimRight());
      previousFlutterError?.call(details);
    };

    final previousPlatformError = ui.PlatformDispatcher.instance.onError;
    ui.PlatformDispatcher.instance.onError = (error, stack) {
      add(RemoteLogLevel.error, '$error\n$stack');
      return previousPlatformError?.call(error, stack) ?? false;
    };
  }
}
