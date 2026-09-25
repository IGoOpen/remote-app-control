# remote_app_control example

A small shop-style app to try remote support: a checkout form with a
password and a masked card field, a long list, images, dialogs, and a
button that throws an error so it shows up in the viewer's logs.

```sh
flutter run
```

Tap **Start support session**, then open the viewer and enter the code.
The app connects to `ws://10.0.2.2:8080` on the Android emulator and
`ws://localhost:8080` elsewhere; override it with
`--dart-define=RELAY_URL=wss://your-server`. See the
[main README](../README.md) for running the relay and viewer.
