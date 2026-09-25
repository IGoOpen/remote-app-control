import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// Hides [child] from remote viewers.
///
/// The child is painted normally on the device, but a remote session only
/// receives an opaque box in its place. Use it for card numbers, personal
/// data, or anything a support agent should not see.
class RemoteMask extends SingleChildRenderObjectWidget {
  const RemoteMask({super.key, super.child});

  @override
  RenderRemoteMask createRenderObject(BuildContext context) => RenderRemoteMask();
}

class RenderRemoteMask extends RenderProxyBox {}
