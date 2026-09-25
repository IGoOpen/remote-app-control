import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../protocol/byte_buffer.dart';
import '../protocol/codec.dart';
import '../protocol/wire.dart';

/// Replays viewer input into the app as if it came from the device itself.
class InputInjector {
  // Keeps injected pointers from colliding with real touches on the device.
  static const int _pointerBase = 0x40000000;
  static const int _device = 0x7ffffff0;

  final Stopwatch _clock = Stopwatch()..start();
  final Map<int, int> _pointers = {};
  final Map<int, Offset> _lastPositions = {};
  int _nextPointer = _pointerBase;

  void handle(int type, ByteReader reader) {
    switch (type) {
      case MessageType.pointer:
        _pointer(reader.u8(), reader.u8(), reader.point());
      case MessageType.scroll:
        _scroll(reader.point(), reader.point());
      case MessageType.textInput:
        _insertText(reader.string());
      case MessageType.key:
        _key(reader.u8());
    }
  }

  int? get _viewId => RendererBinding.instance.renderViews.firstOrNull?.flutterView.viewId;

  void _pointer(int phase, int remoteId, Offset position) {
    final viewId = _viewId;
    if (viewId == null) return;
    final timeStamp = _clock.elapsed;

    final PointerEvent event;
    switch (phase) {
      case PointerPhase.down:
        final pointer = _nextPointer++;
        _pointers[remoteId] = pointer;
        _lastPositions[remoteId] = position;
        event = PointerDownEvent(
          viewId: viewId,
          timeStamp: timeStamp,
          pointer: pointer,
          device: _device,
          position: position,
        );
      case PointerPhase.move:
        final pointer = _pointers[remoteId];
        if (pointer == null) return;
        final delta = position - (_lastPositions[remoteId] ?? position);
        _lastPositions[remoteId] = position;
        event = PointerMoveEvent(
          viewId: viewId,
          timeStamp: timeStamp,
          pointer: pointer,
          device: _device,
          position: position,
          delta: delta,
          buttons: kPrimaryButton,
        );
      case PointerPhase.up:
      case PointerPhase.cancel:
        final pointer = _pointers.remove(remoteId);
        _lastPositions.remove(remoteId);
        if (pointer == null) return;
        event = phase == PointerPhase.up
            ? PointerUpEvent(
                viewId: viewId,
                timeStamp: timeStamp,
                pointer: pointer,
                device: _device,
                position: position,
              )
            : PointerCancelEvent(
                viewId: viewId,
                timeStamp: timeStamp,
                pointer: pointer,
                device: _device,
                position: position,
              );
      default:
        return;
    }
    GestureBinding.instance.handlePointerEvent(event);
  }

  void _scroll(Offset position, Offset delta) {
    final viewId = _viewId;
    if (viewId == null) return;
    GestureBinding.instance.handlePointerEvent(
      PointerScrollEvent(
        viewId: viewId,
        timeStamp: _clock.elapsed,
        kind: PointerDeviceKind.mouse,
        device: _device,
        position: position,
        scrollDelta: delta,
      ),
    );
  }

  /// The text field that currently has focus, if any.
  EditableTextState? get _editable {
    final context = FocusManager.instance.primaryFocus?.context;
    if (context == null) return null;
    if (context is StatefulElement && context.state is EditableTextState) {
      return context.state as EditableTextState;
    }
    return context.findAncestorStateOfType<EditableTextState>();
  }

  void _insertText(String text) {
    final editable = _editable;
    if (editable == null || editable.widget.readOnly) return;
    final value = editable.textEditingValue;
    final selection = _validSelection(value);
    final updated = value.text.replaceRange(selection.start, selection.end, text);
    editable.userUpdateTextEditingValue(
      TextEditingValue(
        text: updated,
        selection: TextSelection.collapsed(offset: selection.start + text.length),
      ),
      SelectionChangedCause.keyboard,
    );
  }

  void _key(int key) {
    if (key == RemoteKey.back) {
      _systemBack();
      return;
    }
    if (key == RemoteKey.tab) {
      FocusManager.instance.primaryFocus?.nextFocus();
      return;
    }

    final editable = _editable;
    if (editable == null) return;
    final value = editable.textEditingValue;
    final selection = _validSelection(value);
    final text = value.text;

    switch (key) {
      case RemoteKey.enter:
        if (editable.widget.maxLines != 1) {
          _insertText('\n');
        } else {
          editable.performAction(editable.widget.textInputAction ?? TextInputAction.done);
        }
      case RemoteKey.backspace || RemoteKey.delete:
        if (editable.widget.readOnly) return;
        var start = selection.start;
        var end = selection.end;
        if (selection.isCollapsed) {
          if (key == RemoteKey.backspace) {
            if (start == 0) return;
            start = text.substring(0, start).characters.skipLast(1).string.length;
          } else {
            if (end >= text.length) return;
            end += text.substring(end).characters.first.length;
          }
        }
        editable.userUpdateTextEditingValue(
          TextEditingValue(
            text: text.replaceRange(start, end, ''),
            selection: TextSelection.collapsed(offset: start),
          ),
          SelectionChangedCause.keyboard,
        );
      case RemoteKey.arrowLeft || RemoteKey.arrowRight:
        final offset = key == RemoteKey.arrowLeft
            ? (selection.isCollapsed
                  ? text.substring(0, selection.start).characters.skipLast(1).string.length
                  : selection.start)
            : (selection.isCollapsed && selection.end < text.length
                  ? selection.end + text.substring(selection.end).characters.first.length
                  : selection.end);
        editable.userUpdateTextEditingValue(
          value.copyWith(selection: TextSelection.collapsed(offset: offset)),
          SelectionChangedCause.keyboard,
        );
    }
  }

  static TextSelection _validSelection(TextEditingValue value) =>
      value.selection.isValid ? value.selection : TextSelection.collapsed(offset: value.text.length);

  /// Delivers a back press exactly like the Android back button does.
  void _systemBack() {
    final message = const JSONMethodCodec().encodeMethodCall(const MethodCall('popRoute'));
    ServicesBinding.instance.channelBuffers.push(SystemChannels.navigation.name, message, (_) {});
  }
}
