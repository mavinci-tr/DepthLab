import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:video_player/video_player.dart';

void main() => runApp(const DepthLabApp());

enum MediaType { photo, video }

class DepthLabApp extends StatelessWidget {
  const DepthLabApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'DepthLab',
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.cyan,
          brightness: Brightness.dark,
        ),
        scaffoldBackgroundColor: const Color(0xFF0C1422),
      ),
      home: const DepthHome(),
    );
  }
}

class DepthHome extends StatefulWidget {
  const DepthHome({super.key});

  @override
  State<DepthHome> createState() => _DepthHomeState();
}

class _DepthHomeState extends State<DepthHome> {
  final ImagePicker _picker = ImagePicker();
  Uint8List? _photo;
  VideoPlayerController? _video;
  String? _fileName;
  MediaType _mediaType = MediaType.photo;
  String _palette = 'Turbo';
  bool _loading = false;

  void _message(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _selectPhoto() async {
    try {
      final file = await _picker.pickImage(source: ImageSource.gallery);
      if (file == null) return;
      final bytes = await file.readAsBytes();
      if (!mounted) return;
      await _video?.pause();
      setState(() {
        _photo = bytes;
        _fileName = file.name;
        _mediaType = MediaType.photo;
      });
    } catch (error) {
      _message('Fotoğraf açılamadı: $error');
    }
  }

  Future<void> _selectVideo() async {
    VideoPlayerController? next;
    try {
      final file = await _picker.pickVideo(source: ImageSource.gallery);
      if (file == null) return;
      setState(() => _loading = true);

      // FlutLab web önizlemesinde seçilen dosyanın Blob URL'si.
      next = VideoPlayerController.networkUrl(Uri.parse(file.path));
      await next.initialize();

      if (!mounted) {
        await next.dispose();
        return;
      }
      final old = _video;
      setState(() {
        _video = next;
        _fileName = file.name;
        _mediaType = MediaType.video;
        _loading = false;
      });
      if (old != null) await old.dispose();
    } catch (error) {
      if (next != null && next != _video) await next.dispose();
      if (mounted) setState(() => _loading = false);
      _message('Video açılamadı: $error');
    }
  }

  void _analyze() {
    final hasInput = _mediaType == MediaType.photo
        ? _photo != null
        : (_video?.value.isInitialized ?? false);
    if (!hasInput) {
      _message('Önce bir fotoğraf veya video yükle.');
      return;
    }
    _message('Model henüz bağlanmadı. Gerçek depth tahmini için model entegrasyonu gerekli.');
  }

  @override
  void dispose() {
    _video?.dispose();
    super.dispose();
  }

  Widget _emptyView(IconData icon, String text) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, size: 55, color: Colors.lightBlueAccent),
          const SizedBox(height: 12),
          Text(text, textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white70)),
        ],
      ),
    );
  }

  Widget _sourceView() {
    if (_mediaType == MediaType.photo) {
      if (_photo == null) {
        return _emptyView(Icons.add_photo_alternate_outlined,
            'Fotoğraf yükleyerek başla');
      }
      return Image.memory(_photo!, fit: BoxFit.contain);
    }

    final player = _video;
    if (player == null || !player.value.isInitialized) {
      return _emptyView(Icons.video_library_outlined, 'Video yükleyerek başla');
    }
    return Column(
      children: [
        Expanded(
          child: Center(
            child: AspectRatio(
              aspectRatio: player.value.aspectRatio,
              child: VideoPlayer(player),
            ),
          ),
        ),
        VideoProgressIndicator(player, allowScrubbing: true),
        ValueListenableBuilder<VideoPlayerValue>(
          valueListenable: player,
          builder: (context, value, _) => IconButton.filledTonal(
            tooltip: value.isPlaying ? 'Duraklat' : 'Oynat',
            onPressed: () => value.isPlaying ? player.pause() : player.play(),
            icon: Icon(value.isPlaying ? Icons.pause : Icons.play_arrow),
          ),
        ),
      ],
    );
  }

  Widget _previewCard(String heading, Widget content, IconData icon) {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF18263B),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFF30445D)),
      ),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(14),
            child: Row(
              children: [
                Icon(icon, size: 18, color: Colors.lightBlueAccent),
                const SizedBox(width: 8),
                Text(heading, style: const TextStyle(fontWeight: FontWeight.bold)),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Center(child: content),
            ),
          ),
        ],
      ),
    );
  }

  Widget _comparison() {
    final left = _previewCard(
      _mediaType == MediaType.photo ? 'Orijinal fotoğraf' : 'Orijinal video',
      _sourceView(),
      Icons.image_outlined,
    );
    final right = _previewCard(
      'Tahmini depth haritası',
      _emptyView(Icons.layers_outlined,
          'Model bağlandığında\nderinlik haritası burada görünecek'),
      Icons.layers_outlined,
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth >= 680) {
          return SizedBox(
            height: 360,
            child: Row(
              children: [
                Expanded(child: left),
                const SizedBox(width: 14),
                Expanded(child: right),
              ],
            ),
          );
        }
        return Column(
          children: [
            SizedBox(height: 310, child: left),
            const SizedBox(height: 14),
            SizedBox(height: 310, child: right),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: const Color(0xFF152338),
        title: const Text('DepthLab',
            style: TextStyle(fontWeight: FontWeight.bold)),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1100),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Depth Estimation',
                    style: TextStyle(fontSize: 29, fontWeight: FontWeight.bold)),
                const SizedBox(height: 5),
                const Text('Fotoğraf ve video için derinlik tahmini',
                    style: TextStyle(color: Colors.white70)),
                const SizedBox(height: 24),
                Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  children: [
                    FilledButton.icon(
                      onPressed: _loading ? null : _selectPhoto,
                      icon: const Icon(Icons.add_photo_alternate_outlined),
                      label: const Text('Fotoğraf yükle'),
                    ),
                    FilledButton.tonalIcon(
                      onPressed: _loading ? null : _selectVideo,
                      icon: const Icon(Icons.video_file_outlined),
                      label: const Text('Video yükle'),
                    ),
                    FilledButton.icon(
                      onPressed: _loading ? null : _analyze,
                      icon: const Icon(Icons.auto_awesome),
                      label: const Text('Analiz Et'),
                    ),
                  ],
                ),
                if (_loading) ...[
                  const SizedBox(height: 12),
                  const LinearProgressIndicator(),
                ],
                if (_fileName != null) ...[
                  const SizedBox(height: 12),
                  Text('Seçili dosya: $_fileName',
                      maxLines: 1, overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: Colors.white70)),
                ],
                const SizedBox(height: 23),
                _comparison(),
                const SizedBox(height: 24),
                const Text('Depth renk paleti',
                    style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 9,
                  children: ['Turbo', 'Inferno', 'Gri tonlama'].map((palette) {
                    return ChoiceChip(
                      label: Text(palette),
                      selected: _palette == palette,
                      onSelected: (_) => setState(() => _palette = palette),
                    );
                  }).toList(),
                ),
                const SizedBox(height: 6),
                const Text('Renk seçimi, model çıktısı bağlandığında uygulanacak.',
                    style: TextStyle(color: Colors.white54, fontSize: 12)),
                const SizedBox(height: 22),
                Card(
                  color: const Color(0xFF18263B),
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Row(
                      children: [
                        const Icon(Icons.info_outline, color: Colors.orangeAccent),
                        const SizedBox(width: 12),
                        const Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('Model durumu: Bağlı değil',
                                  style: TextStyle(fontWeight: FontWeight.bold)),
                              SizedBox(height: 4),
                              Text('Yükleme ve önizleme kullanılabilir. '
                                  'Gerçek depth tahmini için model bağlantısı gerekiyor.',
                                  style: TextStyle(color: Colors.white70)),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
