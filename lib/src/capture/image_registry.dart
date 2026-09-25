import 'dart:ui' as ui;

/// An image waiting to be uploaded.
class PendingImage {
  PendingImage(this.id, this.image, this.scale);

  final int id;
  final ui.Image image;

  /// Fraction of the image's resolution actually needed on screen; images
  /// shown smaller than their size are downscaled before upload.
  double scale;
}

/// Assigns wire ids to images and tracks which ones the viewer still needs.
///
/// Image bytes are sent once per id; frames only reference the id.
class ImageRegistry {
  ImageRegistry() {
    _finalizer = Finalizer<int>(_released.add);
  }

  Expando<int> _ids = Expando<int>('remote image id');
  late final Finalizer<int> _finalizer;
  int _nextId = 1;

  final Map<int, PendingImage> _pending = {};
  final List<int> _released = [];

  /// Returns the id for [image], queueing it for upload the first time.
  int idFor(ui.Image image, {double scale = 1}) {
    final existing = _ids[image];
    if (existing != null) {
      final pending = _pending[existing];
      if (pending != null && scale > pending.scale) pending.scale = scale;
      return existing;
    }
    final id = _nextId++;
    _ids[image] = id;
    // Clone so the upload survives the app disposing its handle.
    _pending[id] = PendingImage(id, image.clone(), scale);
    _finalizer.attach(image, id);
    return id;
  }

  /// Registers an image the capture pipeline created and owns.
  int register(ui.Image image) {
    final id = _nextId++;
    _pending[id] = PendingImage(id, image, 1);
    return id;
  }

  void release(int id) => _released.add(id);

  /// Images recorded since the last call. The caller disposes them.
  List<PendingImage> takePending() {
    if (_pending.isEmpty) return const [];
    final out = List.of(_pending.values);
    _pending.clear();
    return out;
  }

  List<int> takeReleased() {
    if (_released.isEmpty) return const [];
    final out = List.of(_released);
    _released.clear();
    return out;
  }

  /// Forgets everything that was sent, e.g. when a new viewer joins and
  /// needs every image again.
  void reset() {
    _ids = Expando<int>('remote image id');
    for (final pending in _pending.values) {
      pending.image.dispose();
    }
    _pending.clear();
    _released.clear();
  }
}
