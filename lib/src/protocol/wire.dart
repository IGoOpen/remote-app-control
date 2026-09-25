/// Wire constants shared by the host app, the viewer and the relay server.
///
/// Every WebSocket message is binary and starts with one [MessageType] byte.
/// See `doc/protocol.md` for the full layout of each message.
library;

/// Bumped on incompatible changes; sent in the hello message.
const int protocolVersion = 4;

abstract final class MessageType {
  // Host -> viewer.
  static const int hello = 1;
  static const int frame = 2;
  static const int image = 3;
  static const int imageRelease = 4;
  static const int log = 5;
  static const int styles = 6;
  static const int font = 7;
  static const int fontOffer = 8;

  // Viewer -> host.
  static const int pointer = 20;
  static const int scroll = 21;
  static const int textInput = 22;
  static const int key = 23;
  static const int fontRequest = 24;

  // Relay server -> host or viewer, JSON payload.
  static const int control = 50;
}

abstract final class PointerPhase {
  static const int down = 0;
  static const int move = 1;
  static const int up = 2;
  static const int cancel = 3;
}

abstract final class RemoteKey {
  static const int backspace = 1;
  static const int enter = 2;
  static const int delete = 3;
  static const int arrowLeft = 4;
  static const int arrowRight = 5;
  static const int tab = 6;
  static const int back = 7;
}

/// Display list opcodes. A frame is a flat sequence of these.
abstract final class Op {
  static const int save = 0x01;
  static const int saveLayer = 0x02;
  static const int restore = 0x03;
  static const int translate = 0x05;
  static const int scale = 0x06;
  static const int rotate = 0x07;
  static const int skew = 0x08;
  static const int transform = 0x09;

  static const int clipRect = 0x10;
  static const int clipRRect = 0x11;
  static const int clipRSuperellipse = 0x12;
  static const int clipPath = 0x13;

  static const int drawColor = 0x20;
  static const int drawLine = 0x21;
  static const int drawPaint = 0x22;
  static const int drawRect = 0x23;
  static const int drawRRect = 0x24;
  static const int drawDRRect = 0x25;
  static const int drawRSuperellipse = 0x26;
  static const int drawOval = 0x27;
  static const int drawCircle = 0x28;
  static const int drawArc = 0x29;
  static const int drawPath = 0x2A;
  static const int drawImageRect = 0x2B;
  static const int drawImageNine = 0x2C;
  static const int drawPoints = 0x2D;
  static const int drawShadow = 0x2E;
  static const int drawText = 0x2F;
  static const int placeholder = 0x30;
  static const int drawChunk = 0x31;
}

/// Bit flags of a frame message.
abstract final class FrameFlag {
  /// The frame carries every live chunk; viewers drop all others first.
  static const int keyframe = 1 << 0;
}

/// Why a region was replaced by a [Op.placeholder].
abstract final class PlaceholderKind {
  static const int platformView = 0;
  static const int texture = 1;
  static const int masked = 2;
  static const int unsupported = 3;
}

/// Bit flags of an encoded Paint.
abstract final class PaintFlag {
  static const int stroke = 1 << 0;
  static const int noAntiAlias = 1 << 1;
  static const int strokeDetails = 1 << 2;
  static const int blendMode = 1 << 3;
  static const int blur = 1 << 4;
  static const int filterQuality = 1 << 5;
  static const int invertColors = 1 << 6;
}

/// Bit flags of an encoded text style.
abstract final class StyleFlag {
  static const int italic = 1 << 0;
  static const int letterSpacing = 1 << 1;
  static const int wordSpacing = 1 << 2;
  static const int decoration = 1 << 3;
  static const int background = 1 << 4;
  static const int shadows = 1 << 5;
}

/// Bit flags of a text run.
abstract final class RunFlag {
  static const int rtl = 1 << 0;
}
