## 0.0.1

* Initial preview: paint-command capture and replay, remote touch, scroll,
  text and back input, log and error streaming, `RemoteMask`, session
  indicator, Flutter viewer widgets, Go relay server.
* Protocol version 2: text is sent as laid-out runs with interned styles,
  bundled fonts are uploaded to viewers, images are downscaled to their
  on-screen size and sent as JPEG when opaque, and uploads no longer delay
  frames.
* TypeScript viewer SDK in `js/` for any web framework.
* Protocol version 3: fonts are offered by SHA-256 and viewers only request
  the ones they have not cached, so each font is downloaded once per viewer.
* Protocol version 4: retained chunks. Each repaint boundary is recorded
  once and re-recorded only when it repaints; frames carry only changed
  chunks, idle screens send nothing, and slow viewers recover through
  keyframes. Fixes `Opacity` and fade transitions being captured fully
  opaque.
