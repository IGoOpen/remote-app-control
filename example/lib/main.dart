import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:remote_app_control/remote_app_control.dart';

/// Override with `--dart-define=RELAY_URL=wss://your-server`.
const String _relayOverride = String.fromEnvironment('RELAY_URL');

Uri get relayUrl {
  if (_relayOverride.isNotEmpty) return Uri.parse(_relayOverride);
  // The Android emulator reaches the host machine through 10.0.2.2.
  final host = !kIsWeb && defaultTargetPlatform == TargetPlatform.android ? '10.0.2.2' : 'localhost';
  return Uri.parse('ws://$host:8080');
}

void main() => RemoteControl.runZoned(() => runApp(const ExampleApp()));

class ExampleApp extends StatelessWidget {
  const ExampleApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Remote Control Demo',
      theme: ThemeData(colorSchemeSeed: Colors.teal, useMaterial3: true),
      builder: (context, child) => RemoteSessionIndicator(child: child!),
      home: const HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  int _counter = 0;

  Future<void> _toggleSupport() async {
    final control = RemoteControl.instance;
    if (control.state.value.isRunning) {
      await control.stop();
      return;
    }
    final state = await control.start(server: relayUrl);
    if (!mounted) return;
    if (state.status == RemoteSessionStatus.error) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not start support: ${state.error}')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Remote Control Demo')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              gradient: const LinearGradient(colors: [Color(0xFF00897B), Color(0xFF3949AB)]),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Need help?',
                  style: TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 8),
                const Text(
                  'Share this app with a support agent. They only see this app, never the rest of your phone.',
                  style: TextStyle(color: Colors.white70),
                ),
                const SizedBox(height: 16),
                ValueListenableBuilder(
                  valueListenable: RemoteControl.instance.state,
                  builder: (context, state, _) => FilledButton.tonalIcon(
                    onPressed: _toggleSupport,
                    icon: Icon(state.isRunning ? Icons.stop_circle_outlined : Icons.support_agent),
                    label: Text(state.isRunning ? 'Stop support session' : 'Start support session'),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          Card(
            child: ListTile(
              leading: const Icon(Icons.add_circle_outline),
              title: Text('Counter: $_counter', style: theme.textTheme.titleMedium),
              subtitle: const Text('Tap to increment'),
              onTap: () {
                setState(() => _counter++);
                debugPrint('Counter incremented to $_counter');
              },
            ),
          ),
          _NavTile(icon: Icons.edit_note, title: 'Checkout form', page: const FormPage()),
          _NavTile(icon: Icons.list, title: 'Long list', page: const ListPage()),
          _NavTile(icon: Icons.image_outlined, title: 'Images & shapes', page: const GalleryPage()),
          Card(
            child: ListTile(
              leading: const Icon(Icons.chat_bubble_outline),
              title: const Text('Show dialog'),
              onTap: () => showDialog<void>(
                context: context,
                builder: (context) => AlertDialog(
                  title: const Text('Confirm order'),
                  content: const Text('Place the order for \$42.00?'),
                  actions: [
                    TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
                    FilledButton(
                      onPressed: () {
                        debugPrint('Order confirmed');
                        Navigator.pop(context);
                      },
                      child: const Text('Confirm'),
                    ),
                  ],
                ),
              ),
            ),
          ),
          Card(
            child: ListTile(
              leading: const Icon(Icons.vertical_align_top),
              title: const Text('Show bottom sheet'),
              onTap: () => showModalBottomSheet<void>(
                context: context,
                builder: (context) => ListView(
                  shrinkWrap: true,
                  children: const [
                    ListTile(leading: Icon(Icons.share), title: Text('Share')),
                    ListTile(leading: Icon(Icons.link), title: Text('Copy link')),
                    ListTile(leading: Icon(Icons.delete_outline), title: Text('Delete')),
                  ],
                ),
              ),
            ),
          ),
          Card(
            child: ListTile(
              leading: Icon(Icons.bug_report_outlined, color: theme.colorScheme.error),
              title: const Text('Throw an error'),
              subtitle: const Text('Shows up in the viewer\'s log panel'),
              onTap: () => throw StateError('Payment service returned 503'),
            ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => setState(() => _counter++),
        child: const Icon(Icons.add),
      ),
    );
  }
}

class _NavTile extends StatelessWidget {
  const _NavTile({required this.icon, required this.title, required this.page});

  final IconData icon;
  final String title;
  final Widget page;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: ListTile(
        leading: Icon(icon),
        title: Text(title),
        trailing: const Icon(Icons.chevron_right),
        onTap: () {
          debugPrint('Opening $title');
          Navigator.push(context, MaterialPageRoute<void>(builder: (_) => page));
        },
      ),
    );
  }
}

class FormPage extends StatefulWidget {
  const FormPage({super.key});

  @override
  State<FormPage> createState() => _FormPageState();
}

class _FormPageState extends State<FormPage> {
  final _formKey = GlobalKey<FormState>();
  bool _newsletter = true;
  String _shipping = 'Standard';

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Checkout')),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            TextFormField(
              decoration: const InputDecoration(labelText: 'Full name', border: OutlineInputBorder()),
              validator: (v) => (v == null || v.isEmpty) ? 'Required' : null,
            ),
            const SizedBox(height: 12),
            TextFormField(
              decoration: const InputDecoration(labelText: 'Email', border: OutlineInputBorder()),
              keyboardType: TextInputType.emailAddress,
            ),
            const SizedBox(height: 12),
            TextFormField(
              decoration: const InputDecoration(labelText: 'Password', border: OutlineInputBorder()),
              obscureText: true,
            ),
            const SizedBox(height: 12),
            // Masked: the agent sees a solid block instead of the card number.
            RemoteMask(
              child: TextFormField(
                decoration: const InputDecoration(labelText: 'Card number', border: OutlineInputBorder()),
                keyboardType: TextInputType.number,
              ),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              initialValue: _shipping,
              decoration: const InputDecoration(labelText: 'Shipping', border: OutlineInputBorder()),
              items: const [
                DropdownMenuItem(value: 'Standard', child: Text('Standard')),
                DropdownMenuItem(value: 'Express', child: Text('Express')),
                DropdownMenuItem(value: 'Pickup', child: Text('Pickup')),
              ],
              onChanged: (v) => setState(() => _shipping = v!),
            ),
            SwitchListTile(
              title: const Text('Subscribe to newsletter'),
              value: _newsletter,
              onChanged: (v) => setState(() => _newsletter = v),
            ),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: () {
                final valid = _formKey.currentState!.validate();
                debugPrint('Checkout submitted, valid: $valid, shipping: $_shipping');
              },
              child: const Text('Pay now'),
            ),
          ],
        ),
      ),
    );
  }
}

class ListPage extends StatelessWidget {
  const ListPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Orders')),
      body: ListView.separated(
        itemCount: 200,
        separatorBuilder: (_, _) => const Divider(height: 1),
        itemBuilder: (context, i) => ListTile(
          leading: CircleAvatar(child: Text('${i + 1}')),
          title: Text('Order #${1000 + i}'),
          subtitle: Text(i.isEven ? 'Delivered' : 'In transit'),
          trailing: Text('\$${(i * 7.5 + 12).toStringAsFixed(2)}'),
          onTap: () => debugPrint('Tapped order #${1000 + i}'),
        ),
      ),
    );
  }
}

class GalleryPage extends StatelessWidget {
  const GalleryPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Images & shapes')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: Image.network(
              'https://picsum.photos/id/1015/800/400',
              height: 180,
              fit: BoxFit.cover,
              errorBuilder: (_, _, _) => Container(
                height: 180,
                color: Colors.grey.shade300,
                alignment: Alignment.center,
                child: const Text('Image unavailable offline'),
              ),
            ),
          ),
          const SizedBox(height: 16),
          const SizedBox(height: 160, child: CustomPaint(painter: _ChartPainter())),
          const SizedBox(height: 16),
          const Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              CircularProgressIndicator(),
              Icon(Icons.favorite, color: Colors.pink, size: 40),
              Chip(label: Text('Premium'), avatar: Icon(Icons.star, size: 18)),
            ],
          ),
          const SizedBox(height: 16),
          Text.rich(
            TextSpan(
              text: 'Rich text with ',
              children: [
                const TextSpan(
                  text: 'bold',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
                const TextSpan(text: ', '),
                TextSpan(
                  text: 'color',
                  style: TextStyle(color: Colors.deepOrange.shade700),
                ),
                const TextSpan(text: ' and '),
                const TextSpan(
                  text: 'underline',
                  style: TextStyle(decoration: TextDecoration.underline),
                ),
                const TextSpan(text: '.'),
              ],
            ),
            style: Theme.of(context).textTheme.titleMedium,
          ),
        ],
      ),
    );
  }
}

class _ChartPainter extends CustomPainter {
  const _ChartPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final values = [0.2, 0.5, 0.35, 0.8, 0.6, 0.9, 0.7];
    final path = Path();
    for (var i = 0; i < values.length; i++) {
      final p = Offset(size.width * i / (values.length - 1), size.height * (1 - values[i]));
      i == 0 ? path.moveTo(p.dx, p.dy) : path.quadraticBezierTo(p.dx - 20, p.dy, p.dx, p.dy);
    }
    canvas.drawRRect(
      RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(12)),
      Paint()..color = Colors.teal.shade50,
    );
    canvas.drawPath(
      path,
      Paint()
        ..color = Colors.teal
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3
        ..strokeCap = StrokeCap.round,
    );
  }

  @override
  bool shouldRepaint(_ChartPainter oldDelegate) => false;
}
