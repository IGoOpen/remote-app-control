import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';

import '../capture/capture_context.dart';
import '../capture/chunk_cache.dart';
import '../capture/font_registry.dart';
import '../capture/image_encoder.dart';
import '../capture/image_registry.dart';
import '../capture/recording_canvas.dart';
import '../capture/style_registry.dart';
import '../capture/text_layout.dart';
import '../protocol/byte_buffer.dart';
import '../protocol/wire.dart';

/// Records the app after each rendered frame and hands encoded messages to
/// [send], throttled to [maxFps].
///
/// Nothing is recorded while stopped, so an idle session costs nothing.
class FrameCapturer {
  FrameCapturer({required this.send, this.maxFps = 20});

  final void Function(Uint8List message) send;
  final int maxFps;

  final ImageRegistry _images = ImageRegistry();
  final RasterCache _rasterCache = RasterCache();
  final StyleRegistry _styles = StyleRegistry();
  final FontRegistry _fonts = FontRegistry();
  late final TextLayoutEncoder _textLayout = TextLayoutEncoder(_styles);
  final ChunkCache _chunks = ChunkCache();

  bool _running = false;
  DateTime _lastCapture = DateTime.fromMillisecondsSinceEpoch(0);
  Timer? _trailing;

  // What viewers were last sent, to skip frames where nothing changed.
  int? _root;
  Size? _size;
  bool _keyframeDue = true;

  // Uploads (images, fonts) run one at a time, off the frame path.
  Future<void> _uploads = Future.value();
  int _generation = 0;

  static final Set<FrameCapturer> _active = {};
  static bool _hooked = false;

  Duration get _interval => Duration(microseconds: 1000000 ~/ maxFps);

  void start() {
    if (_running) return;
    _running = true;
    _active.add(this);
    if (!_hooked) {
      _hooked = true;
      // Persistent callbacks cannot be removed, so one hook serves every
      // capturer and checks the active set.
      SchedulerBinding.instance.addPersistentFrameCallback((_) {
        if (_active.isEmpty) return;
        SchedulerBinding.instance.addPostFrameCallback((_) {
          for (final capturer in List.of(_active)) {
            capturer._onFrameRendered();
          }
        });
      });
    }
    captureNow();
  }

  void stop() {
    _running = false;
    _active.remove(this);
    _trailing?.cancel();
    _trailing = null;
  }

  /// Drops everything the viewers were sent so the next frame is complete.
  void reset() {
    _generation++;
    _images.reset();
    _rasterCache.clear();
    _styles.reset();
    _fonts.reset();
    _chunks.clear();
    _keyframeDue = true;
  }

  /// Sends every live chunk again, e.g. when the relay had to drop frames
  /// for a slow viewer. Uses the cached recordings; nothing is re-painted.
  void sendKeyframe() {
    final root = _root;
    final size = _size;
    if (!_running || root == null || size == null) {
      _keyframeDue = true;
      return;
    }
    send(encodeFrame(FrameFlag.keyframe, size, root, _chunks.live, const []));
  }

  /// Answers a viewer asking for a font it has no cached copy of.
  void sendFont(List<int> hash) {
    final generation = _generation;
    _uploads = _uploads
        .then((_) async {
          final message = await _fonts.fontFor(hash);
          if (message != null && generation == _generation && _running) send(message);
        })
        .catchError((Object error) {
          debugPrint('remote_app_control: font upload failed: $error');
        });
  }

  /// Encodes a frame message: `u8 flags`, `f32 width`, `f32 height`,
  /// `varuint root`, the chunks (`varuint id`, `varuint length`, bytes) and
  /// released chunk ids.
  static Uint8List encodeFrame(int flags, Size size, int root, Iterable<Chunk> chunks, List<int> released) {
    final list = chunks.toList();
    final w = ByteWriter(64 + list.fold(0, (n, c) => n + c.bytes.length + 8))
      ..u8(MessageType.frame)
      ..u8(flags)
      ..f32(size.width)
      ..f32(size.height)
      ..varUint(root)
      ..varUint(list.length);
    for (final chunk in list) {
      w
        ..varUint(chunk.id)
        ..varUint(chunk.bytes.length)
        ..bytes(chunk.bytes);
    }
    w.varUint(released.length);
    released.forEach(w.varUint);
    return w.takeBytes();
  }

  void captureNow() {
    if (!_running) return;
    SchedulerBinding.instance.addPostFrameCallback((_) => _capture());
    SchedulerBinding.instance.scheduleFrame();
  }

  void _onFrameRendered() {
    if (!_running) return;
    final elapsed = DateTime.now().difference(_lastCapture);
    if (elapsed >= _interval) {
      _capture();
      return;
    }
    // Make sure the last frame of an animation is always sent.
    _trailing ??= Timer(_interval - elapsed, () {
      _trailing = null;
      if (!_running || SchedulerBinding.instance.hasScheduledFrame) return;
      _capture();
    });
  }

  void _capture() {
    if (!_running) return;
    final view = RendererBinding.instance.renderViews.firstOrNull;
    if (view == null) return;
    _lastCapture = DateTime.now();

    final size = view.size;
    final canvas = RecordingCanvas(
      bounds: Offset.zero & size,
      devicePixelRatio: view.flutterView.devicePixelRatio,
      images: _images,
      rasterCache: _rasterCache,
      textLayout: _textLayout,
    );
    int? root;
    _chunks.beginFrame();
    try {
      root = CaptureContext.record(view, canvas, _chunks);
    } catch (error, stack) {
      debugPrint('remote_app_control: frame capture failed: $error\n$stack');
    }
    if (root == null) return;
    final (changed, releasedChunks) = _chunks.endFrame();

    final keyframe = _keyframeDue;
    if (!keyframe && changed.isEmpty && releasedChunks.isEmpty && root == _root && size == _size) return;
    _keyframeDue = false;
    _root = root;
    _size = size;

    // Style definitions are tiny and must precede the frame using them.
    final styles = _styles.takePending(MessageType.styles);
    if (styles != null) send(styles);
    send(
      keyframe
          ? encodeFrame(FrameFlag.keyframe, size, root, _chunks.live, const [])
          : encodeFrame(0, size, root, changed, releasedChunks),
    );

    // Images and fonts follow asynchronously; viewers draw them as they
    // arrive, so a large photo never stalls the live view.
    final images = _images.takePending();
    final families = _styles.takeNewFamilies();
    final released = _images.takeReleased();
    if (released.isNotEmpty) {
      final writer = ByteWriter()
        ..u8(MessageType.imageRelease)
        ..varUint(released.length);
      released.forEach(writer.varUint);
      send(writer.takeBytes());
    }
    if (images.isEmpty && families.isEmpty) return;
    final generation = _generation;
    _uploads = _uploads
        .then((_) async {
          for (final pending in images) {
            if (generation != _generation) {
              pending.image.dispose();
              continue;
            }
            final message = await encodeImageMessage(pending);
            if (message != null && generation == _generation && _running) send(message);
          }
          await for (final message in _fonts.offersFor(families)) {
            if (generation == _generation && _running) send(message);
          }
        })
        .catchError((Object error) {
          debugPrint('remote_app_control: upload failed: $error');
        });
  }
}
