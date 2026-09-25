import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../protocol/byte_buffer.dart';
import '../protocol/codec.dart';
import '../protocol/wire.dart';
import 'remote_resources.dart';

/// Connection state of a [RemoteViewerController].
enum RemoteViewerStatus {
  /// Not connected.
  idle,

  /// Opening the connection to the relay.
  connecting,

  /// Joined the session; the app has not sent its screen yet, or has left.
  waitingForDevice,

  /// Receiving the app's screen.
  connected,

  /// The connection closed; see [RemoteViewerController.error].
  disconnected,
}

/// A line of output or an error reported by the remote app.
class RemoteLog {
  const RemoteLog(this.time, this.isError, this.message);

  /// When the app logged it, on the device's clock.
  final DateTime time;

  /// Whether this is an uncaught error rather than printed output.
  final bool isError;
  final String message;
}

/// A frame: the app's logical size and the root of its chunk tree, whose
/// chunks live in [RemoteResources.chunks].
class RemoteFrame {
  const RemoteFrame(this.size, this.root);

  /// The app's size in logical pixels.
  final Size size;

  /// Id of the chunk to draw, in [RemoteResources.chunks].
  final int root;
}

/// Connects to a shared app through the relay server and exposes its screen,
/// logs and an input channel back to it.
class RemoteViewerController extends ChangeNotifier {
  /// [fontCache] keeps fonts between sessions; see [RemoteFontCache].
  RemoteViewerController({this.logLimit = 2000, RemoteFontCache? fontCache})
    : resources = RemoteResources(fontCache: fontCache);

  /// Oldest log entries are dropped beyond this many.
  final int logLimit;

  RemoteViewerStatus _status = RemoteViewerStatus.idle;
  RemoteViewerStatus get status => _status;

  String? _error;

  /// Why the connection closed or failed, if it did.
  String? get error => _error;

  RemoteFrame? _frame;

  /// The latest frame, or null before the app's screen arrives.
  RemoteFrame? get frame => _frame;

  Map<String, Object?> _deviceInfo = const {};

  /// What the app reported on joining: `protocol`, `platform` and
  /// `devicePixelRatio`.
  Map<String, Object?> get deviceInfo => _deviceInfo;

  /// Images, styles and fonts sent by the host.
  final RemoteResources resources;

  final Queue<RemoteLog> _logs = Queue();

  /// The app's logs and errors, oldest first.
  List<RemoteLog> get logs => _logs.toList(growable: false);

  /// Incremented whenever the log list changes, cheap to compare in widgets.
  final ValueNotifier<int> logRevision = ValueNotifier(0);

  WebSocketChannel? _channel;
  StreamSubscription<Object?>? _subscription;

  // Bumped on every reconnect so late image decodes from an old session are
  // dropped.
  int _generation = 0;

  /// Joins the session with [code] on the relay at [server], for example
  /// `wss://support.example.com`.
  Future<void> connect({required Uri server, required String code}) async {
    await disconnect();
    _setStatus(RemoteViewerStatus.connecting);
    final uri = server.replace(
      path: '${server.path.replaceAll(RegExp(r'/$'), '')}/ws/viewer',
      queryParameters: {...server.queryParameters, 'code': code},
    );
    try {
      final channel = WebSocketChannel.connect(uri);
      _channel = channel;
      await channel.ready;
      _setStatus(RemoteViewerStatus.waitingForDevice);
      _subscription = channel.stream.listen(
        _onMessage,
        onDone: () => _onClosed(channel.closeReason),
        onError: (Object e) => _onClosed('$e'),
      );
    } catch (e) {
      _onClosed('$e');
    }
  }

  /// Leaves the session and forgets its screen.
  Future<void> disconnect() async {
    _generation++;
    await _subscription?.cancel();
    _subscription = null;
    await _channel?.sink.close();
    _channel = null;
    resources.clear();
    _frame = null;
    _setStatus(RemoteViewerStatus.idle);
  }

  void _onClosed(String? reason) {
    _channel = null;
    _error = reason;
    _setStatus(RemoteViewerStatus.disconnected);
  }

  void _setStatus(RemoteViewerStatus status) {
    _status = status;
    if (!_disposed) notifyListeners();
  }

  void _onMessage(Object? data) {
    if (data is! List<int>) return;
    final bytes = data is Uint8List ? data : Uint8List.fromList(data);
    if (bytes.isEmpty) return;
    final r = ByteReader(bytes, 1);
    switch (bytes[0]) {
      case MessageType.hello:
        _deviceInfo = jsonDecode(utf8.decode(r.rest())) as Map<String, Object?>;
        resources.clear();
        _status = RemoteViewerStatus.connected;
        notifyListeners();
      case MessageType.frame:
        final flags = r.u8();
        final size = Size(r.f32(), r.f32());
        final root = r.varUint();
        final chunks = resources.chunks;
        if (flags & FrameFlag.keyframe != 0) chunks.clear();
        for (var n = r.varUint(); n > 0; n--) {
          final id = r.varUint();
          // Copy so a chunk does not keep its whole message alive.
          chunks[id] = Uint8List.fromList(r.bytes(r.varUint()));
        }
        for (var n = r.varUint(); n > 0; n--) {
          chunks.remove(r.varUint());
        }
        _frame = RemoteFrame(size, root);
        _status = RemoteViewerStatus.connected;
        notifyListeners();
      case MessageType.image:
        _decodeImage(r.varUint(), r.varUint(), r.varUint(), r.rest());
      case MessageType.imageRelease:
        final count = r.varUint();
        for (var i = 0; i < count; i++) {
          resources.releaseImage(r.varUint());
        }
      case MessageType.styles:
        resources.addStyles(r);
      case MessageType.fontOffer:
        final generation = _generation;
        resources.addFontOffer(r).then((missing) {
          if (generation != _generation || _disposed) return;
          if (missing != null) {
            _send(
              ByteWriter(40)
                ..u8(MessageType.fontRequest)
                ..bytes(missing),
            );
          } else {
            notifyListeners();
          }
        });
      case MessageType.font:
        final generation = _generation;
        resources.addFont(r).then((_) {
          if (generation == _generation && !_disposed) notifyListeners();
        });
      case MessageType.log:
        _addLogs(jsonDecode(utf8.decode(r.rest())) as List<Object?>);
      case MessageType.control:
        final message = jsonDecode(utf8.decode(r.rest())) as Map<String, Object?>;
        if (message['event'] == 'device_left') {
          _frame = null;
          _setStatus(RemoteViewerStatus.waitingForDevice);
        } else if (message['event'] == 'error') {
          _error = message['message'] as String?;
          notifyListeners();
        }
    }
  }

  Future<void> _decodeImage(int id, int originalWidth, int originalHeight, Uint8List bytes) async {
    final generation = _generation;
    // Copy: the message buffer is a view that may be reused.
    final codec = await ui.instantiateImageCodec(Uint8List.fromList(bytes));
    final frame = await codec.getNextFrame();
    codec.dispose();
    if (generation != _generation) {
      frame.image.dispose();
      return;
    }
    resources.setImage(id, RemoteImage(frame.image, originalWidth, originalHeight));
    if (!_disposed) notifyListeners();
  }

  void _addLogs(List<Object?> entries) {
    for (final entry in entries.cast<Map<String, Object?>>()) {
      _logs.addLast(
        RemoteLog(
          DateTime.fromMillisecondsSinceEpoch((entry['t'] as num).toInt()),
          entry['l'] == 'error',
          entry['m'] as String? ?? '',
        ),
      );
      if (_logs.length > logLimit) _logs.removeFirst();
    }
    logRevision.value++;
  }

  /// Empties [logs].
  void clearLogs() {
    _logs.clear();
    logRevision.value++;
  }

  void _send(ByteWriter writer) {
    if (_status != RemoteViewerStatus.connected) return;
    _channel?.sink.add(writer.takeBytes());
  }

  /// [position] is in the app's logical coordinates.
  void sendPointer(int phase, int pointer, Offset position) => _send(
    ByteWriter(16)
      ..u8(MessageType.pointer)
      ..u8(phase)
      ..u8(pointer & 0xff)
      ..point(position),
  );

  /// Scrolls by [delta] at [position], both in the app's logical pixels.
  void sendScroll(Offset position, Offset delta) => _send(
    ByteWriter(24)
      ..u8(MessageType.scroll)
      ..point(position)
      ..point(delta),
  );

  /// Types [text] into the focused text field of the app.
  void sendText(String text) => _send(
    ByteWriter()
      ..u8(MessageType.textInput)
      ..string(text),
  );

  /// Presses one of the [RemoteKey]s.
  void sendKey(int key) => _send(
    ByteWriter(2)
      ..u8(MessageType.key)
      ..u8(key),
  );

  bool _disposed = false;

  @override
  void dispose() {
    _disposed = true;
    disconnect();
    logRevision.dispose();
    super.dispose();
  }
}
