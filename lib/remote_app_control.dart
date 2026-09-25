/// Share a Flutter app with a remote viewer for support and debugging.
///
/// This library is used inside the app being shared. To build a viewer, use
/// `package:remote_app_control/viewer.dart`.
library;

export 'src/host/log_capture.dart' show RemoteLogLevel;
export 'src/host/remote_control.dart';
export 'src/widgets/remote_mask.dart' show RemoteMask;
export 'src/widgets/remote_session_indicator.dart';
