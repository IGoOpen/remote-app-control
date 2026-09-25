# remote_app_control

[![pub package](https://img.shields.io/pub/v/remote_app_control.svg)](https://pub.dev/packages/remote_app_control)
[![CI](https://github.com/IGoOpen/remote-app-control/actions/workflows/ci.yml/badge.svg)](https://github.com/IGoOpen/remote-app-control/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

See and control a Flutter app remotely, for customer support and debugging.

A support agent opens a web page, enters the code shown in the user's app, and
sees the app live. They can tap, scroll, type and go back, and they get the
app's logs and errors. Only the app is shared, never the rest of the device.

## How it works

The package does not stream video. After every frame it re-paints the render
tree into a recording canvas and sends the resulting paint commands (rects,
paths, images, clips, transforms). Text is sent already laid out by the
device as positioned runs, so a viewer needs no text layout engine: any
canvas can reproduce the screen.

- **Pure Dart, every platform.** No screen capture APIs, no permissions, no
  native code.
- **Any viewer.** A Flutter viewer and a dependency-free TypeScript SDK for
  React, Vue or plain JS are included. The [protocol](doc/protocol.md) is
  documented and backed by test vectors.
- **Only what changed.** Each Flutter repaint boundary is recorded once
  and kept by the viewer; a frame carries only the parts that repainted
  (a scrolling list moves its rows by reference), and an idle screen sends
  nothing. Consecutive frames also compress to almost nothing. Text
  styles and images are sent once per session, fonts once per viewer
  (cached by hash). Photos go as JPEG, downscaled to their on-screen size.
- **Private by design.** Obscured text fields are sent as dots, and anything
  wrapped in `RemoteMask` is replaced by a solid block before it leaves the
  device.
- **Only while watched.** Nothing is captured until a viewer joins.

```
 App (this package) ──ws──▶ relay server (Go) ◀──ws── viewer (web SDK / Flutter)
      paint commands, logs ─────────────────────────▶
      ◀───────────────────────────── taps, scrolls, text, back
```

## Repository

| Path | What | Published as |
| --- | --- | --- |
| [`/`](lib) | Flutter package for the shared app, plus Flutter viewer widgets | [`remote_app_control`](https://pub.dev/packages/remote_app_control) on pub.dev |
| [`server/`](server) | Relay server and embeddable Go package | `go get github.com/IGoOpen/remote-app-control/server` |
| [`js/`](js) | TypeScript viewer SDK for any web framework | [`@igoopen/remote-app-control`](https://www.npmjs.com/package/@igoopen/remote-app-control) on npm |
| [`viewer/`](viewer) | Ready-made viewer app (web, desktop, mobile) | |
| [`example/`](example) | Demo app to share | |

## Install

```sh
flutter pub add remote_app_control
```

## Usage

```dart
import 'package:remote_app_control/remote_app_control.dart';

void main() => RemoteControl.runZoned(() => runApp(const MyApp()));

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      // Shows the support code and a "being shared" banner with a stop button.
      builder: (context, child) => RemoteSessionIndicator(child: child!),
      home: const HomePage(),
    );
  }
}

// When the user asks for help:
final session = await RemoteControl.instance.start(
  server: Uri.parse('wss://support.example.com'),
);
print('Tell the agent this code: ${session.code}');
```

Hide sensitive widgets from the viewer:

```dart
RemoteMask(child: CardNumberField())
```

Set `RemoteControl.instance.allowInput = false` for view-only sessions.

`RemoteControl.runZoned` captures `print`/`debugPrint` output. Uncaught
Flutter and platform errors are captured once a session starts, without
replacing your own error handlers.

### Android

Add the internet permission to `android/app/src/main/AndroidManifest.xml`:

```xml
<uses-permission android:name="android.permission.INTERNET"/>
```

## Running the demo

Requires Flutter and Go.

```sh
# 1. Build the web viewer (keep full icon fonts; the viewer must draw any
#    icon the remote app uses).
cd viewer && flutter build web --release --no-tree-shake-icons && cd ..

# 2. Start the relay, which also serves the viewer.
cd server && go run ./cmd/remote-relay -web ../viewer/build/web

# 3. Run the example app (the Android emulator reaches the host at 10.0.2.2).
cd example && flutter run

# 4. Tap "Start support session", then open http://localhost:8080 and enter the code.
```

In the viewer, the mouse acts as a finger, the wheel scrolls, typing goes to
the focused text field and Escape is the system back button.

## Viewers

- **Web, any framework:** [`js/`](js/README.md) is a TypeScript SDK with no
  dependencies. It includes a connection, a Canvas 2D renderer and an input
  handler, plus a plain HTML demo.
- **Flutter:** `package:remote_app_control/viewer.dart` provides
  `RemoteViewerController`, `RemoteScreen` and `RemoteLogView`. The
  `viewer/` app uses them and runs on web, desktop and mobile.

## Server

`server/relay` is a Go package you can embed in an existing backend, with
hooks to authenticate devices and viewers. `server/cmd/remote-relay` is a
ready-to-run binary. See [server/README.md](server/README.md).

## Limitations

- Shaders (gradients), pictures and some effects are sent as small rasterized
  images. Color filters, backdrop blurs and shader masks on layers are
  currently drawn without the effect.
- Platform views (maps, web views, native video) appear as gray placeholders.
- The app's bundled fonts are sent to viewers automatically and cached by
  content hash, so each font file is downloaded once per viewer, not once
  per session. System fonts (Roboto, San Francisco) are not sent; viewers
  use local fallbacks stretched to the original text widths.
- Text input goes to the focused `EditableText`; IME composition is not
  forwarded.
- Only the first `FlutterView` is shared.

## Protocol and transport

See [doc/protocol.md](doc/protocol.md).

Messages travel over WebSocket with `permessage-deflate` and context
takeover. The alternatives were weighed:

- **gRPC:** browsers cannot open bidirectional gRPC streams (gRPC-Web needs a
  proxy and is server-streaming only), and Protobuf encodes this workload,
  thousands of tiny drawing operations, larger than the hand-packed format.
- **WebTransport (HTTP/3):** avoids head-of-line blocking but has no Dart
  client on mobile and patchy browser support.
- **WebRTC data channels:** peer-to-peer with lower latency, but needs STUN
  and TURN infrastructure. The transport is isolated so it can be added
  later without changing the protocol.

Compression with context takeover means each frame costs roughly what
changed since the previous one, which is the main bandwidth saving.
