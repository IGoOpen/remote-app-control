# @igoopen/remote-app-control

Watch and control Flutter apps shared with
[`remote_app_control`](https://github.com/IGoOpen/remote-app-control) from any web page: React, Vue,
Angular, Svelte or plain JavaScript. No Flutter needed on the viewer side
and no runtime dependencies.

The app sends paint commands with text already laid out, and this package
draws them with the browser's Canvas 2D API.

## Usage

```ts
import { RemoteScreen, RemoteViewer } from '@igoopen/remote-app-control';

const viewer = new RemoteViewer({ server: 'wss://support.example.com' });
const screen = new RemoteScreen(document.getElementById('screen')!, viewer);

viewer.on('status', (status) => console.log(status));
viewer.on('logs', (entries) => entries.forEach((e) => console.log(e.message)));

await viewer.connect('123456'); // The code shown in the user's app.

// Later:
viewer.back();
screen.destroy();
viewer.disconnect();
```

`RemoteScreen` fills its container, scales the app to fit, and forwards
input: the mouse acts as a finger, the wheel scrolls, typing goes to the
focused text field, paste works, and Escape is the system back button. Pass
`{ interactive: false }` for view-only.

### React

```tsx
function RemoteApp({ server, code }: { server: string; code: string }) {
  const ref = useRef<HTMLDivElement>(null);
  useEffect(() => {
    const viewer = new RemoteViewer({ server });
    const screen = new RemoteScreen(ref.current!, viewer);
    viewer.connect(code).catch(() => {});
    return () => {
      screen.destroy();
      viewer.disconnect();
    };
  }, [server, code]);
  return <div ref={ref} style={{ width: 420, height: 800 }} />;
}
```

### Vue

```vue
<script setup lang="ts">
const el = ref<HTMLElement>();
let viewer: RemoteViewer, screen: RemoteScreen;
onMounted(() => {
  viewer = new RemoteViewer({ server: props.server });
  screen = new RemoteScreen(el.value!, viewer);
  viewer.connect(props.code);
});
onUnmounted(() => { screen.destroy(); viewer.disconnect(); });
</script>
<template><div ref="el" style="width: 420px; height: 800px" /></template>
```

## Fonts

The app offers its bundled fonts (custom fonts, icon fonts) by SHA-256.
The viewer downloads each file once, verifies it, and keeps it in IndexedDB
(64 MB, least recently used first), so later sessions and page reloads
reuse it. Pass `fontCache` to use your own storage. Verification needs
WebCrypto, which is only available on https or localhost; elsewhere fonts
are used for the page but not cached.

System fonts are not sent, so text uses local fallbacks per host platform
(Roboto for Android, the system UI font for iOS). Each text run is stretched
to the width it had on the device, so layout stays exact even with a
different font. For identical glyphs, load the platform font on your page,
or map families:

```ts
new RemoteViewer({
  server,
  familyAliases: { MyBrandFont: 'My Brand Font' },
  defaultFonts: { android: 'Roboto, sans-serif' },
});
```

## Custom renderers

`decodeDisplayList(ops, sink)` calls a `DisplayListSink` for every drawing
operation, so you can render to SVG, WebGL, or record for analysis.
`CanvasRenderer` is the built-in sink.

## Development

```sh
npm install
npm test          # decodes the protocol test vectors
npm run check     # type-check
npm run build     # emits dist/
npm run demo      # bundles demo/, then serve demo/ with any static server
```

The relay must allow the page's origin for cross-origin use:
`remote-relay -allow-origin localhost:5173`.
