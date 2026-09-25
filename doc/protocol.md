# Wire protocol (version 4)

All messages are binary WebSocket messages. The first byte is the message
type; the rest is the payload. Numbers are little-endian. `varuint` is
unsigned LEB128, `f32` is an IEEE 754 float, `string` is a `varuint` byte
length followed by UTF-8. Constants live in `lib/src/protocol/wire.dart`.

The relay only reads the type byte (and a frame's flags byte). It forwards
host messages to every viewer and input messages (types 20–29) to the host.
See [Frames and backpressure](#frames-and-backpressure).

## Endpoints

| Path | Who | Query |
| --- | --- | --- |
| `/ws/device` | the shared app | `token` (optional, checked by the server) |
| `/ws/viewer` | a viewer | `code` (session code) |

## Control (50) — relay to host or viewer

JSON payload.

| Event | To | Fields |
| --- | --- | --- |
| `session` | host | `code` |
| `keyframe` | host | (a viewer fell behind; send a keyframe) |
| `viewers` | host | `count`, `joined` (true when a viewer just joined) |
| `device_left` | viewer | |
| `error` | both | `message` |

Viewer rejections use close codes `4404` (unknown code), `4429` (too many
attempts or viewers) and `4410` (the app ended the session).

## Host to viewer

| Type | Name | Payload |
| --- | --- | --- |
| 1 | hello | JSON `{protocol, platform, devicePixelRatio}`. Viewers drop all images and styles. |
| 2 | frame | `u8 flags`, `f32 width`, `f32 height` (logical pixels), `varuint root`, `varuint n` × (`varuint id`, `varuint length`, chunk bytes), `varuint m` × `varuint releasedId` |
| 3 | image | `varuint id`, `varuint originalWidth`, `varuint originalHeight`, PNG or JPEG bytes |
| 4 | imageRelease | `varuint count`, `count × varuint id` |
| 5 | log | JSON array of `{t: epoch ms, l: "info"\|"error", m: message}` |
| 6 | styles | `varuint count`, then `count ×` (`varuint id`, style) |
| 7 | font | `32 bytes sha256`, font file bytes. Sent only in answer to a `fontRequest`. |
| 8 | fontOffer | `string family`, `string familyKey`, `u16 weight` (0 = unspecified), `u8 italic`, `32 bytes sha256`, `varuint size` |

Ordering rules:

- A `styles` message always arrives before the first frame that uses its ids.
- Images and fonts are uploaded in the background and may arrive after the
  frames that reference them. Viewers skip missing images and use fallback
  fonts, then redraw when the resource arrives.
- The host may downscale an image to the size it is displayed at. Frame
  coordinates (`src` rectangles, nine-slice centers) always refer to the
  original size, so viewers scale them by `actual / original`.
- Opaque images are sent as JPEG, others as PNG. Both are self-describing.
- Fonts are the app's bundled font files (custom and icon fonts). System
  fonts are not sent; viewers use local fallbacks. See [Fonts](#fonts).

When a viewer joins, the host sends `hello`, the log history, then a complete
frame with its styles, followed by the images and fonts it needs.

## Frames and backpressure

The screen is a tree of **chunks**, one per Flutter repaint boundary. A
chunk is a display list that may reference child chunks with `drawChunk`.
Chunks are retained by the viewer between frames:

- A frame carries only the chunks that changed (new content replaces the
  chunk with the same id), plus ids of chunks no longer on screen.
- A frame with flag `0x01` (**keyframe**) carries every live chunk; the
  viewer drops all chunks it had before applying it.
- The frame's `root` is the chunk to draw; the frame size is the app's
  logical size.

The host re-records only boundaries that repainted since the last frame,
and sends nothing at all when the screen did not change.

Frames only make sense in order, so the relay never drops a delta and
then sends the next one. When a viewer's queue is full, the relay drops
frames for that viewer until a keyframe fits, and asks the host for one
with a `keyframe` control event (rate limited per session). The host
answers from its cached chunks without re-recording. Other message types
are never dropped; a viewer that cannot keep up with them is disconnected.

## Viewer to host

| Type | Name | Payload |
| --- | --- | --- |
| 20 | pointer | `u8 phase` (0 down, 1 move, 2 up, 3 cancel), `u8 pointer`, `f32 x`, `f32 y` |
| 21 | scroll | `f32 x`, `f32 y`, `f32 dx`, `f32 dy` |
| 22 | textInput | `string`, inserted at the focused field's selection |
| 23 | key | `u8`: 1 backspace, 2 enter, 3 delete, 4 left, 5 right, 6 tab, 7 back |
| 24 | fontRequest | `32 bytes sha256` of an offered font the viewer does not have |

## Fonts

Fonts are content-addressed so each file crosses the network once per
viewer, not once per session:

1. The first time a style uses a bundled family, the host sends one
   `fontOffer` per file of that family.
2. A viewer that has the hash cached (in IndexedDB, for example) loads it
   locally. Otherwise it sends `fontRequest`.
3. The host answers with `font`. Viewers must check that the bytes hash to
   the requested value before using or caching them, so a host cannot plant
   a file under another font's hash.

Register fonts under a name derived from `familyKey` (a hash of the
family's files), not the family name itself, so they never collide with the
page's fonts or another app's font of the same name. With several viewers,
the relay delivers a `font` to all of them; viewers ignore hashes they did
not request or already have.

Coordinates are in the app's logical pixels.

## Display list

A flat sequence of operations, each an opcode byte followed by its arguments.
The viewer applies them to a canvas in order.

Shared encodings:

- `point`: `f32 x, f32 y`
- `rect`: `f32 left, top, right, bottom`
- `rrect`: `rect`, then `f32` x/y radii for top-left, top-right,
  bottom-right, bottom-left (also used for rounded superellipses)
- `color`: `u32` ARGB
- `path`: `u8 fillType`, `varuint contours`, then per contour
  `u8 closed`, `varuint n`, `n × f32` (x, y pairs). Curves are pre-flattened.
- `paint`: `color`, `u8 flags`, then optional fields in flag order:
  - `0x04` stroke details: `f32 width`, `u8 cap`, `u8 join`, `f32 miterLimit`
  - `0x08` blend mode: `u8`
  - `0x10` blur mask filter: `u8 style`, `f32 sigma`
  - `0x20` filter quality: `u8`

  Flag `0x01` means stroke style, `0x02` disables anti-aliasing and `0x40`
  inverts colors.

| Op | Name | Arguments |
| --- | --- | --- |
| 0x01 | save | |
| 0x02 | saveLayer | `u8 hasBounds`, [`rect`], `paint` |
| 0x03 | restore | |
| 0x05 | translate | `f32 dx, dy` |
| 0x06 | scale | `f32 sx, sy` |
| 0x07 | rotate | `f32 radians` |
| 0x08 | skew | `f32 sx, sy` |
| 0x09 | transform | `16 × f32`, column-major |
| 0x10 | clipRect | `rect`, `u8 clipOp`, `u8 antiAlias` |
| 0x11 | clipRRect | `rrect`, `u8 antiAlias` |
| 0x12 | clipRSuperellipse | `rrect`, `u8 antiAlias` |
| 0x13 | clipPath | `path`, `u8 antiAlias` |
| 0x20 | drawColor | `color`, `u8 blendMode` |
| 0x21 | drawLine | `point`, `point`, `paint` |
| 0x22 | drawPaint | `paint` |
| 0x23 | drawRect | `rect`, `paint` |
| 0x24 | drawRRect | `rrect`, `paint` |
| 0x25 | drawDRRect | `rrect outer`, `rrect inner`, `paint` |
| 0x26 | drawRSuperellipse | `rrect`, `paint` |
| 0x27 | drawOval | `rect`, `paint` |
| 0x28 | drawCircle | `point`, `f32 radius`, `paint` |
| 0x29 | drawArc | `rect`, `f32 start`, `f32 sweep`, `u8 useCenter`, `paint` |
| 0x2A | drawPath | `path`, `paint` |
| 0x2B | drawImageRect | `varuint imageId`, `rect src`, `rect dst`, `paint` |
| 0x2C | drawImageNine | `varuint imageId`, `rect center`, `rect dst`, `paint` |
| 0x2D | drawPoints | `u8 pointMode`, `varuint n`, `n × f32`, `paint` |
| 0x2E | drawShadow | `path`, `color`, `f32 elevation`, `u8 transparentOccluder` |
| 0x2F | drawText | see below |
| 0x30 | placeholder | `rect`, `u8 kind` (0 platform view, 1 texture, 2 masked, 3 unsupported) |
| 0x31 | drawChunk | `varuint id`, `point offset`: draw that chunk with its origin at `offset` |

### drawText

Text arrives already laid out by the host: line breaking, alignment,
bidi and ellipsis are done, so a viewer only draws each run at its box.

`point origin`, `varuint count`, then per run:

- `varuint style` (an id from a `styles` message)
- `string text`
- `rect box`, relative to `origin`: the run's extent on its line
- `f32 baseline`, relative to `origin`
- `u8 flags`: `0x01` right-to-left

Draw the text with its alphabetic baseline at `baseline`, starting at
`box.left` (or ending at `box.right` for right-to-left runs). Fonts on the
viewer may measure slightly differently; scale the run horizontally to
`box` width to keep lines exactly as laid out. Draw `background` as a
rectangle over `box` first.

### Text style

`color`, `f32 fontSize` (text scaling applied), `u16 weight`, `u8 flags`,
`string family` (empty for the platform default), `varuint n` fallback
families as strings, then the optional fields in flag order:

| Flag | Field |
| --- | --- |
| `0x01` | italic (no payload) |
| `0x02` | `f32 letterSpacing` |
| `0x04` | `f32 wordSpacing` |
| `0x08` | decoration: `u8` bits (1 underline, 2 overline, 4 line-through), `color`, `u8 style` (solid, double, dotted, dashed, wavy), `f32 thickness` |
| `0x10` | `color background` |
| `0x20` | shadows: `varuint n`, each `color`, `point offset`, `f32 blur` |

## Conformance

`js/test/vectors/` holds recorded messages from a real screen
(`material_screen.bin`: each message prefixed by a `u32` length) and the
facts a decoder must reproduce (`material_screen.json`). Any new viewer
implementation should decode them. Regenerate with
`flutter test test/vectors_test.dart --dart-define=UPDATE_VECTORS=true`.
