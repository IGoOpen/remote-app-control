import 'package:flutter/material.dart';

import '../host/remote_control.dart';

/// Shows the session code while waiting, and a clear "being viewed" banner
/// with a stop button while a viewer is connected.
///
/// Place it above your navigator, typically in `MaterialApp.builder`:
///
/// ```dart
/// MaterialApp(builder: (context, child) => RemoteSessionIndicator(child: child!));
/// ```
class RemoteSessionIndicator extends StatelessWidget {
  const RemoteSessionIndicator({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final control = RemoteControl.instance;
    return Stack(
      children: [
        child,
        ValueListenableBuilder<RemoteSessionState>(
          valueListenable: control.state,
          builder: (context, state, _) {
            final String label;
            switch (state.status) {
              case RemoteSessionStatus.waiting:
                label = 'Support code: ${state.code}';
              case RemoteSessionStatus.active:
                label = 'Your screen is being shared';
              case RemoteSessionStatus.connecting:
                label = 'Connecting…';
              case RemoteSessionStatus.idle || RemoteSessionStatus.error:
                return const SizedBox.shrink();
            }
            return Positioned(
              top: MediaQuery.paddingOf(context).top + 8,
              left: 0,
              right: 0,
              child: Center(
                child: Material(
                  color: state.status == RemoteSessionStatus.active ? const Color(0xFFD32F2F) : const Color(0xFF263238),
                  borderRadius: BorderRadius.circular(24),
                  elevation: 4,
                  child: Padding(
                    padding: const EdgeInsets.only(left: 16, right: 4),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(label, style: const TextStyle(color: Colors.white, fontSize: 13)),
                        // No tooltip: this sits outside the navigator's Overlay.
                        IconButton(
                          visualDensity: VisualDensity.compact,
                          icon: const Icon(Icons.close, color: Colors.white, size: 18),
                          onPressed: control.stop,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ],
    );
  }
}
