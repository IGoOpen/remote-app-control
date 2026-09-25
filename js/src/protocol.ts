// Wire constants. Must match lib/src/protocol/wire.dart and doc/protocol.md.

export const PROTOCOL_VERSION = 4;

export const MessageType = {
  hello: 1,
  frame: 2,
  image: 3,
  imageRelease: 4,
  log: 5,
  styles: 6,
  font: 7,
  fontOffer: 8,
  pointer: 20,
  scroll: 21,
  textInput: 22,
  key: 23,
  fontRequest: 24,
  control: 50,
} as const;

export const PointerPhase = {
  down: 0,
  move: 1,
  up: 2,
  cancel: 3,
} as const;

export const RemoteKey = {
  backspace: 1,
  enter: 2,
  delete: 3,
  arrowLeft: 4,
  arrowRight: 5,
  tab: 6,
  back: 7,
} as const;

export const Op = {
  save: 0x01,
  saveLayer: 0x02,
  restore: 0x03,
  translate: 0x05,
  scale: 0x06,
  rotate: 0x07,
  skew: 0x08,
  transform: 0x09,
  clipRect: 0x10,
  clipRRect: 0x11,
  clipRSuperellipse: 0x12,
  clipPath: 0x13,
  drawColor: 0x20,
  drawLine: 0x21,
  drawPaint: 0x22,
  drawRect: 0x23,
  drawRRect: 0x24,
  drawDRRect: 0x25,
  drawRSuperellipse: 0x26,
  drawOval: 0x27,
  drawCircle: 0x28,
  drawArc: 0x29,
  drawPath: 0x2a,
  drawImageRect: 0x2b,
  drawImageNine: 0x2c,
  drawPoints: 0x2d,
  drawShadow: 0x2e,
  drawText: 0x2f,
  placeholder: 0x30,
  drawChunk: 0x31,
} as const;

export const FrameFlag = {
  /** The frame carries every live chunk; drop all others first. */
  keyframe: 1 << 0,
} as const;

export const PlaceholderKind = {
  platformView: 0,
  texture: 1,
  masked: 2,
  unsupported: 3,
} as const;

export const PaintFlag = {
  stroke: 1 << 0,
  noAntiAlias: 1 << 1,
  strokeDetails: 1 << 2,
  blendMode: 1 << 3,
  blur: 1 << 4,
  filterQuality: 1 << 5,
  invertColors: 1 << 6,
} as const;

export const StyleFlag = {
  italic: 1 << 0,
  letterSpacing: 1 << 1,
  wordSpacing: 1 << 2,
  decoration: 1 << 3,
  background: 1 << 4,
  shadows: 1 << 5,
} as const;

export const RunFlag = {
  rtl: 1 << 0,
} as const;

/** Flutter's BlendMode enum order. */
export const BlendMode = [
  'clear', 'src', 'dst', 'srcOver', 'dstOver', 'srcIn', 'dstIn', 'srcOut', 'dstOut',
  'srcATop', 'dstATop', 'xor', 'plus', 'modulate', 'screen', 'overlay', 'darken',
  'lighten', 'colorDodge', 'colorBurn', 'hardLight', 'softLight', 'difference',
  'exclusion', 'multiply', 'hue', 'saturation', 'color', 'luminosity',
] as const;
