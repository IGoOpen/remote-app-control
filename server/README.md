# Relay server

Pairs apps shared with `remote_app_control` with their viewers and forwards
messages between them. It never decodes frames, so it stays small and fast.

## Run

```sh
go run ./cmd/remote-relay -addr :8080 -web ../viewer/build/web
```

| Flag | Env | Description |
| --- | --- | --- |
| `-addr` | | Listen address, default `:8080` |
| `-web` | | Directory of the built web viewer to serve at `/` |
| `-device-token` | `RELAY_DEVICE_TOKEN` | Require apps to pass this token |
| `-admin-token` | `RELAY_ADMIN_TOKEN` | Enable `GET /api/sessions` with this bearer token |

Run it behind TLS in production (for example behind a reverse proxy) and point
apps at `wss://`.

## Embed

```go
hub := relay.NewHub(relay.Options{
	AuthorizeDevice: func(r *http.Request) error {
		return checkAppToken(r.URL.Query().Get("token"))
	},
	AuthorizeViewer: func(r *http.Request, code string) error {
		return requireSupportAgent(r) // e.g. your session cookie
	},
})
mux.Handle("/ws/", hub)
```

`hub.Sessions()` lists live sessions for dashboards.

## Security

- Session codes come from `crypto/rand`, and each client IP gets a limited
  number of failed joins per minute (`FailedJoinsPerMinute`).
- Viewers can only send input messages; everything else is dropped.
- Use `AuthorizeViewer` so that only your support staff can join, not anyone
  who learns a code.

## Slow viewers

Frames are deltas, so they cannot simply be skipped. When a viewer's send
queue is full, the relay stops sending it frames until a keyframe (a
complete frame) fits, and asks the app for one. Other viewers are not
affected.

## Test

```sh
go test ./...
```
