import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../protocol/byte_buffer.dart';
import '../protocol/wire.dart';
import 'frame_capturer.dart';
import 'input_injector.dart';
import 'log_capture.dart';

enum RemoteSessionStatus {
  idle,
  connecting,

  /// Connected to the server, waiting for someone to join with [RemoteSessionState.code].
  waiting,

  /// At least one viewer is watching the app.
  active,
  error,
}

/// Where a sharing session stands; see [RemoteControl.state].
@immutable
class RemoteSessionState {
  const RemoteSessionState({this.status = RemoteSessionStatus.idle, this.code, this.viewers = 0, this.error});

  final RemoteSessionStatus status;

  /// The code a viewer enters to join this session.
  final String? code;

  /// How many viewers are watching.
  final int viewers;

  /// Why the session failed, when [status] is [RemoteSessionStatus.error].
  final String? error;

  /// Whether a session is open or being opened.
  bool get isRunning =>
      status == RemoteSessionStatus.connecting ||
      status == RemoteSessionStatus.waiting ||
      status == RemoteSessionStatus.active;
}

/// Shares this app with remote viewers through a relay server.
///
/// ```dart
/// void main() => RemoteControl.runZoned(() => runApp(const MyApp()));
///
/// await RemoteControl.instance.start(server: Uri.parse('wss://support.example.com'));
/// ```
class RemoteControl {
  RemoteControl._();

  /// The app's single remote control.
  static final RemoteControl instance = RemoteControl._();

  /// Runs [body] with `print` output and uncaught errors captured, so they
  /// can be streamed to viewers. Wrap your `runApp` call with it.
  static R runZoned<R>(R Function() body) => LogCapture.instance.runZoned(body);

  final ValueNotifier<RemoteSessionState> state = ValueNotifier(const RemoteSessionState());

  /// Whether viewers may control the app, not just watch it.
  bool allowInput = true;

  WebSocketChannel? _channel;
  StreamSubscription<Object?>? _subscription;
  StreamSubscription<RemoteLogEntry>? _logSubscription;
  FrameCapturer? _capturer;
  final InputInjector _input = InputInjector();
  final List<RemoteLogEntry> _pendingLogs = [];
  Timer? _logFlush;

  /// Opens a session on [server] and resolves once the server has assigned
  /// the session code.
  ///
  /// [token] is forwarded to the server, which can use it to authenticate
  /// the device.
  Future<RemoteSessionState> start({required Uri server, String? token, int maxFps = 20}) async {
    await stop();
    LogCapture.instance.installErrorHooks();
    state.value = const RemoteSessionState(status: RemoteSessionStatus.connecting);

    final query = {...server.queryParameters, 'token': ?token};
    final uri = server.replace(
      path: '${server.path.replaceAll(RegExp(r'/$'), '')}/ws/device',
      queryParameters: query.isEmpty ? null : query,
    );
    final ready = Completer<RemoteSessionState>();
    try {
      final channel = WebSocketChannel.connect(uri);
      _channel = channel;
      await channel.ready;
      _capturer = FrameCapturer(send: _send, maxFps: maxFps);
      _subscription = channel.stream.listen(
        (data) => _onMessage(data, ready),
        onDone: () => _onClosed(ready, channel.closeReason ?? 'Connection closed'),
        onError: (Object error) => _onClosed(ready, '$error'),
      );
    } catch (error) {
      _onClosed(ready, '$error');
    }
    return ready.future;
  }

  Future<void> stop() async {
    _capturer?.stop();
    _capturer = null;
    await _logSubscription?.cancel();
    _logSubscription = null;
    _logFlush?.cancel();
    _pendingLogs.clear();
    await _subscription?.cancel();
    _subscription = null;
    await _channel?.sink.close();
    _channel = null;
    state.value = const RemoteSessionState();
  }

  void _send(Uint8List message) => _channel?.sink.add(message);

  void _onMessage(Object? data, Completer<RemoteSessionState> ready) {
    if (data is! List<int>) return;
    final bytes = data is Uint8List ? data : Uint8List.fromList(data);
    if (bytes.isEmpty) return;
    final reader = ByteReader(bytes, 1);
    final type = bytes[0];
    if (type == MessageType.control) {
      _onControl(jsonDecode(utf8.decode(reader.rest())) as Map<String, Object?>, ready);
    } else if (type == MessageType.fontRequest) {
      if (bytes.length >= 33) _capturer?.sendFont(bytes.sublist(1, 33));
    } else if (allowInput && state.value.status == RemoteSessionStatus.active) {
      _input.handle(type, reader);
    }
  }

  void _onControl(Map<String, Object?> message, Completer<RemoteSessionState> ready) {
    switch (message['event']) {
      case 'session':
        state.value = RemoteSessionState(status: RemoteSessionStatus.waiting, code: message['code'] as String?);
        if (!ready.isCompleted) ready.complete(state.value);
      case 'viewers':
        final viewers = (message['count'] as num?)?.toInt() ?? 0;
        final joined = message['joined'] == true;
        state.value = RemoteSessionState(
          status: viewers > 0 ? RemoteSessionStatus.active : RemoteSessionStatus.waiting,
          code: state.value.code,
          viewers: viewers,
        );
        if (viewers == 0) {
          _capturer?.stop();
          _logSubscription?.cancel();
          _logSubscription = null;
        } else if (joined) {
          _onViewerJoined();
        }
      case 'keyframe':
        // The relay dropped frames for a slow viewer and needs a full one.
        _capturer?.sendKeyframe();
      case 'error':
        _onClosed(ready, message['message'] as String? ?? 'Server error');
    }
  }

  /// Every viewer starts from a clean slate: metadata, log history, then a
  /// complete frame with all its images.
  void _onViewerJoined() {
    final view = RendererBinding.instance.renderViews.firstOrNull;
    _sendJson(MessageType.hello, {
      'protocol': protocolVersion,
      'platform': defaultTargetPlatform.name,
      'devicePixelRatio': view?.flutterView.devicePixelRatio,
    });
    _sendJson(MessageType.log, [for (final e in LogCapture.instance.history) e.toJson()]);
    _logSubscription ??= LogCapture.instance.entries.listen((entry) {
      _pendingLogs.add(entry);
      _logFlush ??= Timer(const Duration(milliseconds: 100), _flushLogs);
    });

    final capturer = _capturer!..reset();
    capturer.start();
    capturer.captureNow();
  }

  void _flushLogs() {
    _logFlush = null;
    if (_pendingLogs.isEmpty) return;
    _sendJson(MessageType.log, [for (final e in _pendingLogs) e.toJson()]);
    _pendingLogs.clear();
  }

  void _sendJson(int type, Object payload) {
    _send(
      (ByteWriter()
            ..u8(type)
            ..bytes(utf8.encode(jsonEncode(payload))))
          .takeBytes(),
    );
  }

  void _onClosed(Completer<RemoteSessionState> ready, String reason) {
    _capturer?.stop();
    _capturer = null;
    _logSubscription?.cancel();
    _logSubscription = null;
    _channel = null;
    state.value = RemoteSessionState(status: RemoteSessionStatus.error, error: reason);
    if (!ready.isCompleted) ready.complete(state.value);
  }
}
