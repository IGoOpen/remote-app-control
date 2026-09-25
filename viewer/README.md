# Remote App Viewer

A ready-made viewer for apps shared with `remote_app_control`: enter the
support code to watch and control the app and read its logs. Runs on web,
desktop and mobile.

Build it for the web and let the relay serve it:

```sh
flutter build web --release --no-tree-shake-icons
cd ../server && go run ./cmd/remote-relay -web ../viewer/build/web
```

`--no-tree-shake-icons` keeps the full icon fonts, since the viewer must draw
whatever icons the remote app uses. Open `http://localhost:8080/?code=123456`
to join a session directly.
