import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../protocol/wire.dart';
import 'display_list_player.dart';
import 'remote_viewer_controller.dart';

/// Displays the remote app and forwards pointer and keyboard input to it.
///
/// Mouse drags become touches on the device, the wheel scrolls, typing goes
/// to the focused text field and Escape triggers the system back action.
class RemoteScreen extends StatefulWidget {
  const RemoteScreen({super.key, required this.controller, this.interactive = true});

  final RemoteViewerController controller;

  /// When false the screen is view-only.
  final bool interactive;

  @override
  State<RemoteScreen> createState() => _RemoteScreenState();
}

class _RemoteScreenState extends State<RemoteScreen> {
  final FocusNode _focus = FocusNode(debugLabel: 'RemoteScreen');
  final Set<int> _down = {};

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.controller,
      builder: (context, _) {
        final frame = widget.controller.frame;
        if (frame == null) return const SizedBox.shrink();
        return LayoutBuilder(
          builder: (context, constraints) {
            final scale = _fitScale(frame.size, constraints.biggest);
            final screen = CustomPaint(
              size: frame.size * scale,
              painter: _FramePainter(frame, widget.controller, scale),
            );
            if (!widget.interactive) return Center(child: screen);
            return Center(
              child: Focus(
                focusNode: _focus,
                autofocus: true,
                onKeyEvent: (_, event) => _onKey(event),
                child: MouseRegion(
                  cursor: SystemMouseCursors.precise,
                  child: Listener(
                    onPointerDown: (e) => _onPointer(e, PointerPhase.down, scale),
                    onPointerMove: (e) => _onPointer(e, PointerPhase.move, scale),
                    onPointerUp: (e) => _onPointer(e, PointerPhase.up, scale),
                    onPointerCancel: (e) => _onPointer(e, PointerPhase.cancel, scale),
                    onPointerSignal: (e) {
                      if (e is PointerScrollEvent) {
                        widget.controller.sendScroll(e.localPosition / scale, e.scrollDelta);
                      }
                    },
                    child: screen,
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }

  static double _fitScale(Size content, Size available) {
    if (content.isEmpty || !available.isFinite) return 1;
    final scale = [available.width / content.width, available.height / content.height].reduce((a, b) => a < b ? a : b);
    return scale.clamp(0.1, 3.0);
  }

  void _onPointer(PointerEvent event, int phase, double scale) {
    if (phase == PointerPhase.down) {
      _focus.requestFocus();
      _down.add(event.pointer);
    } else if (!_down.contains(event.pointer)) {
      return;
    }
    if (phase == PointerPhase.up || phase == PointerPhase.cancel) _down.remove(event.pointer);
    widget.controller.sendPointer(phase, event.pointer, event.localPosition / scale);
  }

  KeyEventResult _onKey(KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) return KeyEventResult.ignored;
    final controller = widget.controller;
    final key = event.logicalKey;
    final keyboard = HardwareKeyboard.instance;

    if ((keyboard.isControlPressed || keyboard.isMetaPressed) && key == LogicalKeyboardKey.keyV) {
      Clipboard.getData(Clipboard.kTextPlain).then((data) {
        final text = data?.text;
        if (text != null && text.isNotEmpty) controller.sendText(text);
      });
      return KeyEventResult.handled;
    }

    final remoteKey = switch (key) {
      LogicalKeyboardKey.backspace => RemoteKey.backspace,
      LogicalKeyboardKey.enter || LogicalKeyboardKey.numpadEnter => RemoteKey.enter,
      LogicalKeyboardKey.delete => RemoteKey.delete,
      LogicalKeyboardKey.arrowLeft => RemoteKey.arrowLeft,
      LogicalKeyboardKey.arrowRight => RemoteKey.arrowRight,
      LogicalKeyboardKey.tab => RemoteKey.tab,
      LogicalKeyboardKey.escape => RemoteKey.back,
      _ => null,
    };
    if (remoteKey != null) {
      controller.sendKey(remoteKey);
      return KeyEventResult.handled;
    }

    final character = event.character;
    if (character != null && character.isNotEmpty && !keyboard.isControlPressed && !keyboard.isMetaPressed) {
      final code = character.codeUnitAt(0);
      if (code >= 0x20 && code != 0x7f) {
        controller.sendText(character);
        return KeyEventResult.handled;
      }
    }
    return KeyEventResult.ignored;
  }
}

class _FramePainter extends CustomPainter {
  _FramePainter(this.frame, this.controller, this.scale);

  final RemoteFrame frame;
  final RemoteViewerController controller;
  final double scale;

  @override
  void paint(Canvas canvas, Size size) {
    canvas
      ..clipRect(Offset.zero & size)
      ..drawRect(Offset.zero & size, Paint()..color = const Color(0xFF000000))
      ..scale(scale);
    final root = controller.resources.chunks[frame.root];
    if (root != null) DisplayListPlayer.play(canvas, root, controller.resources);
  }

  // The controller notifies on every new frame or image, which rebuilds this
  // painter, so any new instance should repaint.
  @override
  bool shouldRepaint(_FramePainter oldDelegate) => true;
}
