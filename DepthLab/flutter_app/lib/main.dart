import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';
import 'package:video_player/video_player.dart';

void main() {
  runApp(const DepthLabApp());
}

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
          seedColor: Colors.blue,
          brightness: Brightness.dark,
        ),
        scaffoldBackgroundColor: const Color(0xFF0B1220),
      ),
      home: const DepthHome(),
    );
  }
}

enum MediaType { none, photo, video }

class DepthHome extends StatefulWidget {
  const DepthHome({super.key});

  @override
  State<DepthHome> createState() => _DepthHomeState();
}

class _DepthHomeState extends State<DepthHome> {
  // Bu adres sadece AYNI bilgisayardaki Web Preview testi icindir.
  // Gercek telefonda localhost telefonun kendisini isaret eder.
  static const String apiBaseUrl = 'http://127.0.0.1:8000';

  final ImagePicker picker = ImagePicker();

  Uint8List? imageBytes;
  Uint8List? depthImageBytes;
  String? depthResultId;
  int? photoWidth;
  int? photoHeight;
  int? selectedPixelX;
  int? selectedPixelY;
  double? selectedDepthMeters;
  String? pixelError;
  bool pixelLoading = false;
  String? analysisError;
  int? analysisTimeMs;

  VideoPlayerController? videoController;
  VideoPlayerController? depthVideoController;
  XFile? selectedVideoFile;
  int? processedFrames;
  double? resultFps;
  // Video: saklanan depth haritasi ve secilen kare/piksel.
  String? videoDepthId;
  int? videoDepthWidth;
  int? videoDepthHeight;
  int? videoTapX;
  int? videoTapY;
  int? videoTapFrame;
  double? videoTapMeters;
  String? videoTapError;
  bool videoTapLoading = false;
  int? scrubbingMs;

  MediaType mediaType = MediaType.none;

  String? fileName;
  String selectedPalette = 'Spectral';

  bool loading = false;
  bool fillImage = false;
  bool showOverlay = true;
  double overlayOpacity = 0.55;

  int selectedPage = 0;

  bool get hasMedia => mediaType != MediaType.none;

  void resetVideoTapState() {
    videoDepthId = null;
    videoDepthWidth = null;
    videoDepthHeight = null;
    videoTapX = null;
    videoTapY = null;
    videoTapFrame = null;
    videoTapMeters = null;
    videoTapError = null;
    videoTapLoading = false;
    scrubbingMs = null;
  }

  void clearVideoSelection() {
    videoTapX = null;
    videoTapY = null;
    videoTapFrame = null;
    videoTapMeters = null;
    videoTapError = null;
    videoTapLoading = false;
  }

  // FOTO YUKLEME / KAMERA ILE CEKILEN FOTOYU AYNI AKISA AL.
  Future<void> setSelectedPhoto(XFile file) async {
    final bytes = await file.readAsBytes();
    if (!mounted) return;
    final oldVideo = videoController;
    final oldResult = depthVideoController;
    setState(() {
      imageBytes = bytes;
      depthImageBytes = null;
      depthResultId = null;
      photoWidth = null;
      photoHeight = null;
      selectedPixelX = null;
      selectedPixelY = null;
      selectedDepthMeters = null;
      pixelError = null;
      pixelLoading = false;
      videoController = null;
      depthVideoController = null;
      selectedVideoFile = null;
      processedFrames = null;
      resultFps = null;
      resetVideoTapState();
      analysisError = null;
      analysisTimeMs = null;
      mediaType = MediaType.photo;
      fileName = file.name;
      selectedPage = 0;
    });
    await oldVideo?.dispose();
    await oldResult?.dispose();
  }

  Future<void> selectImage() async {
    if (loading) return;
    setState(() => loading = true);
    try {
      final file = await picker.pickImage(source: ImageSource.gallery);
      if (file != null) await setSelectedPhoto(file);
    } catch (error) {
      showError(error);
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  // GERCEK KAMERA ONIZLEMESIYLE CEKIM YAP, SONRA OTOMATIK ANALIZ ET.
  Future<void> takeCameraPhoto() async {
    if (loading) return;
    XFile? captured;
    setState(() => loading = true);
    try {
      final cameras = await availableCameras();
      if (cameras.isEmpty) {
        throw Exception('Bu cihazda erisilebilir kamera yok.');
      }
      if (!mounted) return;
      setState(() => loading = false);
      captured = await Navigator.of(context).push<XFile>(
        MaterialPageRoute(
          builder: (_) => DepthCameraPage(camera: cameras.first),
        ),
      );
      if (captured == null || !mounted) return;
      setState(() => loading = true);
      await setSelectedPhoto(captured);
    } catch (error) {
      showError('Kamera acilamadi: $error');
    } finally {
      if (mounted) setState(() => loading = false);
    }
    if (captured != null && mounted && imageBytes != null) {
      await analyze(); // Fotograf cekilince ayrica Analiz Et'e basmaya gerek yok.
    }
  }

  // VIDEO YUKLEME: dosya nesnesini sakliyoruz, backend'e gonderecegiz.
  Future<void> selectVideo() async {
    if (loading) return;
    setState(() => loading = true);
    VideoPlayerController? nextController;
    try {
      final file = await picker.pickVideo(source: ImageSource.gallery);
      if (file == null) return;
      // Bu surum FlutLab Web Preview testini hedefliyor.
      nextController = VideoPlayerController.networkUrl(Uri.parse(file.path));
      await nextController.initialize();
      if (!mounted) {
        await nextController.dispose();
        return;
      }
      final oldVideo = videoController;
      final oldResult = depthVideoController;
      setState(() {
        videoController = nextController;
        depthVideoController = null;
        selectedVideoFile = file;
        imageBytes = null;
        depthImageBytes = null;
        depthResultId = null;
        photoWidth = null;
        photoHeight = null;
        selectedPixelX = null;
        selectedPixelY = null;
        selectedDepthMeters = null;
        pixelError = null;
        pixelLoading = false;
        processedFrames = null;
        resultFps = null;
        resetVideoTapState();
        analysisError = null;
        analysisTimeMs = null;
        fileName = file.name;
        mediaType = MediaType.video;
        selectedPage = 0;
      });
      await oldVideo?.dispose();
      await oldResult?.dispose();
    } catch (error) {
      if (nextController != null && nextController != videoController) {
        await nextController.dispose();
      }
      showError(error);
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  // Ayrı kamera modu: foto/video analizini etkilemeden otomatik olcum yapar.
  Future<void> openLiveDepthCamera() async {
    if (loading) return;
    setState(() => loading = true);
    try {
      final cameras = await availableCameras();
      if (cameras.isEmpty) {
        throw Exception('Kullanilabilir kamera bulunamadi.');
      }
      // Bilgisayardaki ilk kamerayı kullan; birden cok varsa arka kamerayi sec.
      final camera = cameras.firstWhere(
        (item) => item.lensDirection == CameraLensDirection.back,
        orElse: () => cameras.first,
      );
      if (!mounted) return;
      setState(() => loading = false);
      await Navigator.of(context).push<void>(
        MaterialPageRoute(
          builder: (_) => LiveDepthCameraPage(
            camera: camera,
            apiBaseUrl: apiBaseUrl,
          ),
        ),
      );
    } catch (error) {
      showError('Canli kamera acilamadi: $error');
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  void showError(Object error) {
    if (!mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Hata: $error'),
      ),
    );
  }

  // FOTOGRAF / KAMERA veya VIDEO icin ayni ANALIZ BUTONU.
  Future<void> analyze() async {
    if (loading) return;
    if (mediaType == MediaType.none) {
      showError('Once bir fotograf veya video secin.');
      return;
    }
    if (mediaType == MediaType.photo && imageBytes == null) {
      showError('Fotograf bellekte bulunamadi; yeniden secin.');
      return;
    }
    if (mediaType == MediaType.video && selectedVideoFile == null) {
      showError('Video dosyasi bulunamadi; yeniden secin.');
      return;
    }
    final clock = Stopwatch()..start();
    setState(() {
      loading = true;
      depthImageBytes = null;
      depthResultId = null;
      photoWidth = null;
      photoHeight = null;
      selectedPixelX = null;
      selectedPixelY = null;
      selectedDepthMeters = null;
      pixelError = null;
      pixelLoading = false;
      analysisError = null;
      analysisTimeMs = null;
      resetVideoTapState();
    });
    VideoPlayerController? nextDepthVideo;
    try {
      final isVideo = mediaType == MediaType.video;
      final bytes = isVideo
          ? await selectedVideoFile!.readAsBytes()
          : imageBytes!;
      if (isVideo && bytes.length > 50 * 1024 * 1024) {
        throw Exception('Ilk video testi icin en fazla 50 MB video secin.');
      }
      final request = http.MultipartRequest(
        'POST',
        Uri.parse('$apiBaseUrl/${isVideo ? 'predict-video' : 'predict'}'),
      );
      request.files.add(http.MultipartFile.fromBytes(
        'file',
        bytes,
        filename: fileName ?? (isVideo ? 'clip.mp4' : 'photo.jpg'),
      ));
      final streamed = await request.send().timeout(
        Duration(minutes: isVideo ? 12 : 3),
      );
      final response = await http.Response.fromStream(streamed);
      if (response.statusCode != 200) {
        throw Exception('API HTTP ${response.statusCode}: ${response.body}');
      }
      if (isVideo) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        final path = data['video_url'] as String?;
        if (path == null || !path.startsWith('/results/')) {
          throw Exception('Sunucu gecerli bir video adresi gondermedi.');
        }
        final newVideoId = data['video_depth_id'] as String?;
        final newVideoWidth = (data['depth_width'] as num?)?.toInt();
        final newVideoHeight = (data['depth_height'] as num?)?.toInt();
        if (newVideoId == null || newVideoWidth == null ||
            newVideoHeight == null) {
          throw Exception('Video icin backend v4 gerekli. server.py dosyasini guncelle.');
        }
        nextDepthVideo = VideoPlayerController.networkUrl(
          Uri.parse('$apiBaseUrl$path'),
        );
        await nextDepthVideo.initialize();
        if (!mounted) {
          await nextDepthVideo.dispose();
          return;
        }
        final previousDepthVideo = depthVideoController;
        clock.stop();
        setState(() {
          depthVideoController = nextDepthVideo;
          videoDepthId = newVideoId;
          videoDepthWidth = newVideoWidth;
          videoDepthHeight = newVideoHeight;
          processedFrames = (data['processed_frames'] as num?)?.toInt();
          resultFps = (data['result_fps'] as num?)?.toDouble();
          analysisTimeMs = clock.elapsedMilliseconds;
          selectedPage = 1;
        });
        await previousDepthVideo?.dispose();
      } else {
        if (!(response.headers['content-type'] ?? '')
            .toLowerCase().contains('image/png') || response.bodyBytes.isEmpty) {
          throw Exception('Sunucu depth PNG donmedi.');
        }
        clock.stop();
        if (!mounted) return;
        final newDepthId = response.headers['x-depth-id'];
        final newWidth = int.tryParse(response.headers['x-image-width'] ?? '');
        final newHeight = int.tryParse(response.headers['x-image-height'] ?? '');
        if (newDepthId == null || newWidth == null || newHeight == null) {
          throw Exception('Backend guncel degil: depth ID/boyut basliklari yok. Yeni server.py dosyasini baslat.');
        }
        setState(() {
          depthImageBytes = response.bodyBytes;
          depthResultId = newDepthId;
          photoWidth = newWidth;
          photoHeight = newHeight;
          analysisTimeMs = clock.elapsedMilliseconds;
          selectedPage = 1;
        });
      }
    } catch (error) {
      clock.stop();
      if (nextDepthVideo != null && nextDepthVideo != depthVideoController) {
        await nextDepthVideo.dispose();
      }
      if (!mounted) return;
      setState(() => analysisError = error.toString());
      showError(error);
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  // DOSYA TEMIZLEME
  Future<void> clearMedia() async {
    if (loading) return;
    final oldController = videoController;
    final oldResult = depthVideoController;
    setState(() {
      imageBytes = null;
      depthImageBytes = null;
      depthResultId = null;
      photoWidth = null;
      photoHeight = null;
      selectedPixelX = null;
      selectedPixelY = null;
      selectedDepthMeters = null;
      pixelError = null;
      pixelLoading = false;
      analysisError = null;
      analysisTimeMs = null;
      videoController = null;
      depthVideoController = null;
      selectedVideoFile = null;
      processedFrames = null;
      resultFps = null;
      resetVideoTapState();
      fileName = null;
      mediaType = MediaType.none;
      selectedPage = 0;
    });
    await oldController?.dispose();
    await oldResult?.dispose();
  }

  void changePage(int index) {
    videoController?.pause();
    depthVideoController?.pause();

    setState(() {
      selectedPage = index;
    });
  }

  @override
  void dispose() {
    videoController?.dispose();
    depthVideoController?.dispose();
    super.dispose();
  }

  // ORTAK TASARIM KARTI
  Widget appCard({
    required Widget child,
  }) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF18263C),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: const Color(0xFF30425C),
        ),
      ),
      child: child,
    );
  }

  // BOS ONIZLEME
  Widget emptyPreview(
    IconData icon,
    String message,
  ) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            icon,
            size: 46,
            color: Colors.lightBlueAccent,
          ),
          const SizedBox(height: 12),
          Padding(
            padding: const EdgeInsets.all(10),
            child: Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Colors.white70,
                fontSize: 13,
              ),
            ),
          ),
        ],
      ),
    );
  }

  // VIDEO OYNATICI
  Widget videoPreview(VideoPlayerController? controller) {
    if (controller == null || !controller.value.isInitialized) {
      return emptyPreview(
        Icons.video_library_outlined,
        'Video henuz hazir degil',
      );
    }

    return Column(
      children: [
        Expanded(
          child: Center(
            child: AspectRatio(
              aspectRatio: controller.value.aspectRatio,
              child: VideoPlayer(controller),
            ),
          ),
        ),
        const SizedBox(height: 8),
        VideoProgressIndicator(
          controller,
          allowScrubbing: true,
          colors: const VideoProgressColors(
            playedColor: Colors.lightBlueAccent,
            bufferedColor: Colors.white24,
          ),
        ),
        const SizedBox(height: 6),
        ValueListenableBuilder<VideoPlayerValue>(
          valueListenable: controller,
          builder: (context, value, child) {
            return IconButton.filled(
              icon: Icon(
                value.isPlaying ? Icons.pause : Icons.play_arrow,
              ),
              onPressed: () async {
                if (value.isPlaying) {
                  await controller.pause();
                } else {
                  await controller.play();
                }
              },
            );
          },
        ),
      ],
    );
  }

  // Video sonucunda iki oynaticiyi tek zaman cizgisinde tutuyoruz.
  Future<void> setVideoPosition(Duration position) async {
    final depth = depthVideoController;
    final rgb = videoController;
    if (depth == null || rgb == null) return;
    await Future.wait([depth.pause(), rgb.pause()]);
    final duration = depth.value.duration;
    final clamped = position > duration ? duration : position;
    await Future.wait([depth.seekTo(clamped), rgb.seekTo(clamped)]);
    if (mounted) setState(clearVideoSelection);
  }

  Future<void> toggleVideoPlayback() async {
    final depth = depthVideoController;
    final rgb = videoController;
    if (depth == null || rgb == null) return;
    if (depth.value.isPlaying) {
      await Future.wait([depth.pause(), rgb.pause()]);
    } else {
      await Future.wait([depth.play(), rgb.play()]);
      if (mounted) setState(clearVideoSelection);
    }
  }

  // Kullanici RGB veya depth video KARESINE tiklayabilir.
  // Dokunulan kare oynatilmiyorsa ve islenmis sonuc mevcutsa sorgula.
  Future<void> onVideoTap(Offset offset, Size box) async {
    final id = videoDepthId;
    final depth = depthVideoController;
    final w = videoDepthWidth;
    final h = videoDepthHeight;
    final fps = resultFps;
    final frames = processedFrames;
    if (id == null || depth == null || !depth.value.isInitialized ||
        w == null || h == null || fps == null || fps <= 0 ||
        frames == null || frames < 1 || videoTapLoading) return;
    // Buton ile durdurulmus olmasi gerekiyor; anlik oynayan kareyi
    // sorgulamak kullaniciyi yaniltir.
    if (depth.value.isPlaying) {
      await Future.wait([depth.pause(), videoController?.pause() ?? Future<void>.value()]);
    }
    final frame = ((depth.value.position.inMilliseconds * fps) / 1000)
        .floor().clamp(0, frames - 1).toInt();
    final x = (offset.dx / box.width * w).floor().clamp(0, w - 1).toInt();
    final y = (offset.dy / box.height * h).floor().clamp(0, h - 1).toInt();
    setState(() {
      videoTapFrame = frame;
      videoTapX = x;
      videoTapY = y;
      videoTapMeters = null;
      videoTapError = null;
      videoTapLoading = true;
    });
    try {
      final uri = Uri.parse('$apiBaseUrl/video-depth-at/$id').replace(
        queryParameters: {'frame': '$frame', 'x': '$x', 'y': '$y'},
      );
      final response = await http.get(uri).timeout(const Duration(seconds: 20));
      if (response.statusCode != 200) {
        throw Exception('Sunucu HTTP ${response.statusCode}: ${response.body}');
      }
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      if (!mounted || videoDepthId != id) return;
      setState(() {
        videoTapMeters = (data['depth_m'] as num?)?.toDouble();
        videoTapError = data['valid'] == true
            ? null : 'Secilen pikselde gecerli derinlik yok.';
      });
    } catch (error) {
      if (!mounted || videoDepthId != id) return;
      setState(() => videoTapError = error.toString());
    } finally {
      if (mounted && videoDepthId == id) {
        setState(() => videoTapLoading = false);
      }
    }
  }

  // Gercek video goruntusunun dikdortgenine dokunma:
  // AspectRatio, siyah bosluklarin hit-test disinda kalmasini saglar.
  Widget interactiveVideoPreview(VideoPlayerController? controller) {
    if (controller == null || !controller.value.isInitialized) {
      return emptyPreview(Icons.video_library_outlined, 'Video henuz hazir degil');
    }
    return Center(
      child: AspectRatio(
        aspectRatio: controller.value.aspectRatio,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final box = Size(constraints.maxWidth, constraints.maxHeight);
            final marker = videoTapX != null && videoTapY != null &&
                    videoDepthWidth != null && videoDepthHeight != null
                ? Offset(
                    (videoTapX! + 0.5) / videoDepthWidth! * box.width,
                    (videoTapY! + 0.5) / videoDepthHeight! * box.height,
                  ) : null;
            return GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTapDown: (details) => onVideoTap(details.localPosition, box),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  VideoPlayer(controller),
                  if (marker != null)
                    Positioned(
                      left: marker.dx - 10,
                      top: marker.dy - 10,
                      child: IgnorePointer(
                        child: Container(
                          width: 20, height: 20,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            border: Border.all(color: Colors.white, width: 2.5),
                            color: Colors.redAccent.withOpacity(0.75),
                          ),
                          child: const Icon(Icons.add, size: 12, color: Colors.white),
                        ),
                      ),
                    ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  Widget videoPlaybackControls() {
    final controller = depthVideoController;
    if (controller == null || !controller.value.isInitialized) {
      return const SizedBox.shrink();
    }
    return ValueListenableBuilder<VideoPlayerValue>(
      valueListenable: controller,
      builder: (context, value, child) {
        final duration = value.duration.inMilliseconds;
        final position = value.position.inMilliseconds.clamp(0, duration).toInt();
        String fmt(int millis) {
          final seconds = (millis / 1000).floor();
          return '${(seconds ~/ 60).toString().padLeft(2, '0')}:${(seconds % 60).toString().padLeft(2, '0')}';
        }
        return appCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Video Kare Secimi',
                  style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
              const SizedBox(height: 6),
              const Text('Oynatmayi durdur, zaman cubugundan kare sec, '
                  'RGB veya depth videosuna tikla.',
                  style: TextStyle(color: Colors.white70)),
              Row(
                children: [
                  IconButton.filled(
                    icon: Icon(value.isPlaying ? Icons.pause : Icons.play_arrow),
                    onPressed: toggleVideoPlayback,
                  ),
                  Expanded(
                    child: Slider(
                      value: duration <= 0
                          ? 0.0 : (scrubbingMs ?? position).toDouble().clamp(0.0, duration.toDouble()).toDouble(),
                      min: 0.0,
                      max: duration <= 0 ? 1.0 : duration.toDouble(),
                      onChangeStart: duration <= 0 ? null : (_) {
                        depthVideoController?.pause();
                        videoController?.pause();
                      },
                      onChanged: duration <= 0 ? null : (v) {
                        setState(() => scrubbingMs = v.round());
                      },
                      onChangeEnd: duration <= 0 ? null : (v) async {
                        setState(() => scrubbingMs = null);
                        await setVideoPosition(Duration(milliseconds: v.round()));
                      },
                    ),
                  ),
                  Text('${fmt(position)}/${fmt(duration)}',
                      style: const TextStyle(fontSize: 12)),
                ],
              ),
            ],
          ),
        );
      },
    );
  }

  // Hit-testing for BoxFit.contain AND BoxFit.cover with center alignment.
  // Works with letterboxing and with cropped zoom-to-fill previews.
  Rect actualImageRect(Size box, BoxFit fit) {
    final iw = photoWidth!.toDouble();
    final ih = photoHeight!.toDouble();
    final fitted = applyBoxFit(fit, Size(iw, ih), box);
    final dest = fitted.destination;
    return Rect.fromLTWH(
      (box.width - dest.width) / 2,
      (box.height - dest.height) / 2,
      dest.width,
      dest.height,
    );
  }

  Offset? pixelToScreen(Size box, BoxFit fit, int x, int y) {
    if (photoWidth == null || photoHeight == null) return null;
    final rect = actualImageRect(box, fit);
    final fitted = applyBoxFit(
      fit,
      Size(photoWidth!.toDouble(), photoHeight!.toDouble()),
      box,
    );
    final cropX = (photoWidth! - fitted.source.width) / 2;
    final cropY = (photoHeight! - fitted.source.height) / 2;
    final rx = ((x + 0.5 - cropX) / fitted.source.width);
    final ry = ((y + 0.5 - cropY) / fitted.source.height);
    if (rx < 0 || rx > 1 || ry < 0 || ry > 1) return null;
    return Offset(rect.left + rx * rect.width, rect.top + ry * rect.height);
  }

  Future<void> onPhotoTap(Offset point, Size box, BoxFit fit) async {
    final id = depthResultId;
    final iw = photoWidth;
    final ih = photoHeight;
    if (id == null || iw == null || ih == null || pixelLoading) return;
    final rect = actualImageRect(box, fit);
    if (!rect.contains(point)) return; // Ignore empty margins.
    final fitted = applyBoxFit(fit, Size(iw.toDouble(), ih.toDouble()), box);
    final cropX = (iw - fitted.source.width) / 2;
    final cropY = (ih - fitted.source.height) / 2;
    final px = (cropX + (point.dx - rect.left) / rect.width * fitted.source.width)
        .floor().clamp(0, iw - 1).toInt();
    final py = (cropY + (point.dy - rect.top) / rect.height * fitted.source.height)
        .floor().clamp(0, ih - 1).toInt();
    setState(() {
      selectedPixelX = px;
      selectedPixelY = py;
      selectedDepthMeters = null;
      pixelError = null;
      pixelLoading = true;
    });
    try {
      final uri = Uri.parse('$apiBaseUrl/depth-at/$id').replace(
        queryParameters: {'x': '$px', 'y': '$py'},
      );
      final response = await http.get(uri).timeout(const Duration(seconds: 20));
      if (response.statusCode != 200) {
        throw Exception('Sunucu HTTP ${response.statusCode}: ${response.body}');
      }
      final result = jsonDecode(response.body) as Map<String, dynamic>;
      if (!mounted || depthResultId != id) return;
      setState(() {
        selectedDepthMeters = (result['depth_m'] as num?)?.toDouble();
        pixelError = result['valid'] == true
            ? null
            : 'Bu piksel icin gecerli derinlik tahmini bulunamadi.';
      });
    } catch (error) {
      if (!mounted || depthResultId != id) return;
      setState(() => pixelError = error.toString());
    } finally {
      if (mounted && depthResultId == id) {
        setState(() => pixelLoading = false);
      }
    }
  }

  Widget interactivePhotoPreview(Uint8List bytes, {required bool depthPanel}) {
    final fit = depthPanel ? BoxFit.contain : (fillImage ? BoxFit.cover : BoxFit.contain);
    return LayoutBuilder(
      builder: (context, constraints) {
        final box = Size(constraints.maxWidth, constraints.maxHeight);
        final marker = selectedPixelX != null && selectedPixelY != null
            ? pixelToScreen(box, fit, selectedPixelX!, selectedPixelY!)
            : null;
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: depthResultId == null
              ? null
              : (details) => onPhotoTap(details.localPosition, box, fit),
          child: Stack(
            fit: StackFit.expand,
            children: [
              Image.memory(
                bytes,
                width: double.infinity,
                height: double.infinity,
                fit: fit,
              ),
              if (marker != null)
                Positioned(
                  left: marker.dx - 10,
                  top: marker.dy - 10,
                  child: IgnorePointer(
                    child: Container(
                      height: 20,
                      width: 20,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(color: Colors.white, width: 2.5),
                        color: Colors.redAccent.withOpacity(0.75),
                      ),
                      child: const Center(
                        child: Icon(Icons.add, color: Colors.white, size: 12),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  // ORIJINAL MEDYA
  Widget originalPreview() {
    if (mediaType == MediaType.photo && imageBytes != null) {
      return interactivePhotoPreview(imageBytes!, depthPanel: false);
    }

    if (mediaType == MediaType.video) {
      return depthVideoController != null
          ? interactiveVideoPreview(videoController)
          : videoPreview(videoController);
    }

    return emptyPreview(
      Icons.add_photo_alternate_outlined,
      'Fotograf veya video yukleyin',
    );
  }

  // DEPTH SONUC ONIZLEMESI
  Widget depthPreview() {
    if (mediaType == MediaType.video && depthVideoController != null) {
      return interactiveVideoPreview(depthVideoController);
    }
    if (depthImageBytes != null) {
      return interactivePhotoPreview(depthImageBytes!, depthPanel: true);
    }

    return emptyPreview(
      Icons.layers_outlined,
      'Henuz depth sonucu yok.\n'
      'Fotograf veya video secip Analiz Et butonuna basin.',
    );
  }


  Widget overlayPhotoPreview() {
    if (imageBytes == null || depthImageBytes == null) {
      return emptyPreview(
        Icons.compare_outlined,
        'Overlay gormek icin fotografi analiz et.',
      );
    }

    const fit = BoxFit.contain;
    return LayoutBuilder(
      builder: (context, constraints) {
        final box = Size(constraints.maxWidth, constraints.maxHeight);
        final marker = selectedPixelX != null && selectedPixelY != null
            ? pixelToScreen(box, fit, selectedPixelX!, selectedPixelY!)
            : null;

        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: depthResultId == null
              ? null
              : (details) => onPhotoTap(details.localPosition, box, fit),
          child: Stack(
            fit: StackFit.expand,
            children: [
              Image.memory(
                imageBytes!,
                width: double.infinity,
                height: double.infinity,
                fit: fit,
              ),
              if (showOverlay)
                Opacity(
                  opacity: overlayOpacity,
                  child: Image.memory(
                    depthImageBytes!,
                    width: double.infinity,
                    height: double.infinity,
                    fit: fit,
                  ),
                ),
              if (marker != null)
                Positioned(
                  left: marker.dx - 10,
                  top: marker.dy - 10,
                  child: IgnorePointer(
                    child: Container(
                      height: 20,
                      width: 20,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(color: Colors.white, width: 2.5),
                        color: Colors.redAccent.withOpacity(0.75),
                      ),
                      child: const Center(
                        child: Icon(Icons.add, size: 12, color: Colors.white),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  Widget overlayControlCard() {
    return appCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.layers_outlined, color: Colors.lightBlueAccent),
              SizedBox(width: 10),
              Text(
                'RGB + Depth Overlay Ayarlari',
                style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold),
              ),
            ],
          ),
          const SizedBox(height: 10),
          const Text(
            'Depth haritasini orijinal goruntunun ustune yari saydam olarak yerlestirir. '
            'Nesne kenarlarini ve ayrinti kayiplarini incelemek icin kullan.',
            style: TextStyle(color: Colors.white70),
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Switch.adaptive(
                value: showOverlay,
                onChanged: (value) {
                  setState(() => showOverlay = value);
                },
              ),
              Expanded(
                child: Text(
                  showOverlay ? 'Overlay acik' : 'Overlay kapali',
                  style: const TextStyle(fontSize: 14),
                ),
              ),
              Text(
                '${(overlayOpacity * 100).round()}%',
                style: const TextStyle(color: Colors.white70),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Opacity(
            opacity: showOverlay ? 1 : 0.45,
            child: IgnorePointer(
              ignoring: !showOverlay,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Depth katmani opakligi',
                    style: TextStyle(color: Colors.white70),
                  ),
                  Slider(
                    value: overlayOpacity,
                    min: 0.0,
                    max: 1.0,
                    divisions: 20,
                    label: overlayOpacity.toStringAsFixed(2),
                    onChanged: (value) {
                      setState(() => overlayOpacity = value);
                    },
                  ),
                  const Text(
                    '0.0 = sadece RGB, 1.0 = sadece depth haritasi',
                    style: TextStyle(fontSize: 12, color: Colors.white54),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  // GORUNTU PANELI
  Widget previewCard(
    String title,
    IconData icon,
    Widget content,
    double height,
  ) {
    return appCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                icon,
                color: Colors.lightBlueAccent,
                size: 20,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          SizedBox(
            height: height,
            width: double.infinity,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: ColoredBox(
                color: const Color(0xFF0C1728),
                child: content,
              ),
            ),
          ),
        ],
      ),
    );
  }

  // MODEL DURUMU: Sunucuya gercek istek basarili olunca onay verilir.
  Widget modelStatus() {
    final ready = depthImageBytes != null || depthVideoController != null;
    final failed = analysisError != null;
    final status = ready
        ? 'Model analiz uretimi basarili'
        : failed
            ? 'Sunucu baglantisi / analiz hatasi'
            : 'Pretrained model - test bekleniyor';
    final statusColor = ready
        ? Colors.greenAccent
        : failed
            ? Colors.redAccent
            : Colors.orangeAccent;

    return appCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Model Durumu',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Icon(ready ? Icons.check_circle_outline : Icons.schedule_outlined,
                  color: statusColor),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  status,
                  style: TextStyle(
                    color: statusColor,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          const Text(
            'Model: YOLO26n-Depth (pretrained, fine-tuning yok)\n'
            'Analiz: Yerel Python / FastAPI sunucusu\n'
            'Fotograf, kamera ve kisa video analizi aktif.',
            style: TextStyle(color: Colors.white70, height: 1.6),
          ),
          if (failed) ...[
            const SizedBox(height: 8),
            Text(analysisError!, style: const TextStyle(color: Colors.redAccent)),
          ],
        ],
      ),
    );
  }

  // ANA ANALIZ SAYFASI
  Widget analysisPage() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Depth Estimation',
          style: TextStyle(
            fontSize: 28,
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 8),
        const Text(
          'Fotograf ve video derinlik analizi',
          style: TextStyle(color: Colors.white70),
        ),
        const SizedBox(height: 24),

        // YUKLEME BUTONLARI
        Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            FilledButton.icon(
              onPressed: loading ? null : selectImage,
              icon: const Icon(Icons.add_photo_alternate),
              label: const Text('Fotograf Yukle'),
            ),
            FilledButton.icon(
              onPressed: loading ? null : takeCameraPhoto,
              icon: const Icon(Icons.camera_alt_outlined),
              label: const Text('Kameradan Cek'),
            ),
            FilledButton.icon(
              onPressed: loading ? null : selectVideo,
              icon: const Icon(Icons.video_file),
              label: const Text('Video Yukle'),
            ),
            FilledButton.icon(
              onPressed: loading ? null : openLiveDepthCamera,
              icon: const Icon(Icons.center_focus_strong),
              label: const Text('Canli Mesafe Olc'),
            ),
            FilledButton.icon(
              onPressed: loading
                  ? null
                  : () => Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => const GroundTruthTestPage(),
                        ),
                      ),
              icon: const Icon(Icons.analytics_outlined),
              label: const Text('GT ile Test Et'),
            ),
            FilledButton.icon(
              style: FilledButton.styleFrom(
                backgroundColor: Colors.green.shade700,
              ),
              onPressed: loading ? null : analyze,
              icon: const Icon(Icons.auto_awesome),
              label: const Text('Analiz Et'),
            ),
          ],
        ),

        if (mediaType == MediaType.video) ...[
          const SizedBox(height: 12),
          const Text(
            'Ilk test icin en fazla 10 saniye, 50 MB video. '
            'Video en fazla 4 FPS derinlik tahminiyle islenir; ses aktarilmaz.',
            style: TextStyle(color: Colors.orangeAccent),
          ),
        ],

        if (loading) ...[
          const SizedBox(height: 15),
          const LinearProgressIndicator(),
          const SizedBox(height: 8),
          Text(mediaType == MediaType.video
              ? 'Video kareleri YOLO ile isleniyor; CPU kullaniminda biraz surebilir.'
              : 'YOLO26-Depth tahmini hesaplaniyor...'),
        ],

        if (fileName != null) ...[
          const SizedBox(height: 20),
          appCard(
            child: Row(
              children: [
                const Icon(
                  Icons.insert_drive_file_outlined,
                  color: Colors.lightBlueAccent,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    fileName!,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                IconButton(
                  tooltip: 'Dosyayi temizle',
                  onPressed: loading ? null : clearMedia,
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
          ),
        ],

        const SizedBox(height: 22),

        // ONIZLEME
        previewCard(
          'Orijinal Goruntu',
          Icons.image_outlined,
          originalPreview(),
          290,
        ),

        if (mediaType == MediaType.photo) ...[
          const SizedBox(height: 12),
          Row(
            children: [
              Switch.adaptive(
                value: fillImage,
                onChanged: (value) {
                  setState(() => fillImage = value);
                },
              ),
              const Expanded(
                child: Text(
                  'Onizlemeyi doldur '
                  '(goruntu kirpilabilir)',
                  style: TextStyle(fontSize: 13),
                ),
              ),
            ],
          ),
        ],

        const SizedBox(height: 22),

        FilledButton.icon(
          onPressed: () => changePage(1),
          icon: const Icon(Icons.arrow_forward),
          label: const Text('Sonuc Ekranini Gor'),
        ),

        const SizedBox(height: 24),
        modelStatus(),
      ],
    );
  }

  // SONUC BILGI KUTUSU
  Widget infoTile(
    String title,
    String value,
    IconData icon,
  ) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF0D192B),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(
            icon,
            color: Colors.lightBlueAccent,
            size: 21,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 12,
                    color: Colors.white60,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  value,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // RENK PALETI ALANI
  Widget paletteCard() {
    return appCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Depth Gorsellestirme',
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 14),
          const Text(
            'Renk Paleti',
            style: TextStyle(color: Colors.white70),
          ),
          const SizedBox(height: 8),
          DropdownButton<String>(
            value: selectedPalette,
            isExpanded: true,
            items: const [
              DropdownMenuItem(
                value: 'Spectral',
                child: Text('Spectral (sunucudaki aktif palet)'),
              ),
              DropdownMenuItem(
                value: 'Turbo',
                child: Text('Turbo'),
              ),
              DropdownMenuItem(
                value: 'Inferno',
                child: Text('Inferno'),
              ),
              DropdownMenuItem(
                value: 'Grayscale',
                child: Text('Gri Tonlama'),
              ),
            ],
            onChanged: null,
          ),
          const SizedBox(height: 8),
          const Text(
            'Bu ilk testte renkleri sunucu Spectral paletiyle uretiyor. '
            'Diger paletler henuz aktif degil.', 
            style: TextStyle(
              fontSize: 12,
              color: Colors.white60,
            ),
          ),
        ],
      ),
    );
  }

  // SONUC INDIRME ALANI
  Widget downloadCard() {
    return appCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Sonucu Kaydet',
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 10),
          const Text(
            'Fotograf depth PNG ve video depth MP4 ekranda goruntulenebilir. '
            'Dosyaya kaydetme butonlari henuz etkin degil.',
            style: TextStyle(color: Colors.white70),
          ),
          const SizedBox(height: 18),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              FilledButton.icon(
                onPressed: null,
                icon: const Icon(Icons.download),
                label: const Text('Depth PNG Indir'),
              ),
              OutlinedButton.icon(
                onPressed: null,
                icon: const Icon(Icons.video_file_outlined),
                label: const Text('Islenmis MP4 Indir'),
              ),
            ],
          ),
          const SizedBox(height: 12),
          const Text(
            'Dosyaya indirme ozelligini sonraki asamada ekleyecegiz.',
            style: TextStyle(
              color: Colors.orangeAccent,
              fontSize: 12,
            ),
          ),
        ],
      ),
    );
  }

  // SONUCLAR SAYFASI
  Widget resultsPage() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Analiz Sonuclari',
          style: TextStyle(
            fontSize: 28,
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 8),
        const Text(
          'Orijinal goruntu ve depth '
          'tahmini karsilastirmasi',
          style: TextStyle(color: Colors.white70),
        ),

        const SizedBox(height: 20),

        appCard(
          child: Row(
            children: [
              Icon(
                (depthImageBytes != null || depthVideoController != null)
                    ? Icons.check_circle_outline
                    : Icons.info_outline,
                color: (depthImageBytes != null || depthVideoController != null)
                    ? Colors.greenAccent
                    : Colors.orangeAccent,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  (depthImageBytes != null || depthVideoController != null)
                      ? 'Gercek depth sonucu pretrained YOLO26-Depth modelinden alindi.'
                      : 'Sonucu gormek icin fotograf/video yukleyip Analiz Et butonuna basin.',
                  style: const TextStyle(color: Colors.white70),
                ),
              ),
            ],
          ),
        ),

        const SizedBox(height: 24),

        // RESPONSIVE KARSILASTIRMA
        LayoutBuilder(
          builder: (context, constraints) {
            final wide = constraints.maxWidth >= 720;
            final panelHeight = wide ? 320.0 : 245.0;

            final original = previewCard(
              'Orijinal Goruntu (RGB)',
              Icons.image_outlined,
              originalPreview(),
              panelHeight,
            );

            final depth = previewCard(
              'Tahmini Depth Haritasi',
              Icons.layers_outlined,
              depthPreview(),
              panelHeight,
            );

            if (wide) {
              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: original),
                  const SizedBox(width: 16),
                  Expanded(child: depth),
                ],
              );
            }

            return Column(
              children: [
                original,
                const SizedBox(height: 16),
                depth,
              ],
            );
          },
        ),


        if (mediaType == MediaType.photo && imageBytes != null && depthImageBytes != null) ...[
          const SizedBox(height: 16),
          previewCard(
            'RGB + Depth Overlay',
            Icons.layers_outlined,
            overlayPhotoPreview(),
            320,
          ),
          const SizedBox(height: 16),
          overlayControlCard(),
        ],

        if (mediaType == MediaType.video && depthVideoController != null) ...[
          const SizedBox(height: 16),
          videoPlaybackControls(),
          const SizedBox(height: 16),
          appCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Row(children: [
                  Icon(Icons.touch_app, color: Colors.lightBlueAccent),
                  SizedBox(width: 10),
                  Text('Videoda Pikselden Tahmini Mesafe',
                      style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
                ]),
                const SizedBox(height: 8),
                const Text(
                  'Videoyu durdurup kareyi sec; her iki panelde de '
                  'bir noktaya tiklayabilirsin. Deger, islenmis '
                  'depth karesinden okunur.',
                  style: TextStyle(color: Colors.white70),
                ),
                const SizedBox(height: 10),
                if (videoTapLoading)
                  const LinearProgressIndicator()
                else if (videoTapMeters != null)
                  Text('Tahmini derinlik: ${videoTapMeters!.toStringAsFixed(2)} m',
                      style: const TextStyle(
                          fontSize: 27, fontWeight: FontWeight.bold,
                          color: Colors.lightGreenAccent))
                else if (videoTapError != null)
                  Text(videoTapError!,
                      style: const TextStyle(color: Colors.orangeAccent))
                else
                  const Text('Bir kareye tiklayarak mesafeyi sorgula.'),
                if (videoTapFrame != null) ...[
                  const SizedBox(height: 6),
                  Text('Kare: ${videoTapFrame! + 1}/$processedFrames  '
                      '| Piksel: x=$videoTapX, y=$videoTapY',
                      style: const TextStyle(color: Colors.white60)),
                ],
                const SizedBox(height: 8),
                const Text(
                  'Not: Video saniyede yaklasik 4 kare analiz eder. '
                  'Gosterilen metre degeri bir tahmindir; sensor olcumu degildir.',
                  style: TextStyle(fontSize: 12, color: Colors.white54),
                ),
              ],
            ),
          ),
        ],

        if (mediaType == MediaType.photo && depthImageBytes != null) ...[
          const SizedBox(height: 16),
          appCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Row(
                  children: [
                    Icon(Icons.touch_app, color: Colors.lightBlueAccent),
                    SizedBox(width: 10),
                    Text('Pikselden Tahmini Mesafe',
                        style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
                  ],
                ),
                const SizedBox(height: 9),
                const Text(
                  'RGB fotografina veya depth haritasina tikla. '
                  'Secilen pikselin sayisal derinlik tahmini gosterilir.',
                  style: TextStyle(color: Colors.white70),
                ),
                const SizedBox(height: 12),
                if (pixelLoading)
                  const LinearProgressIndicator()
                else if (selectedDepthMeters != null)
                  Text(
                    'Tahmini derinlik: ${selectedDepthMeters!.toStringAsFixed(2)} m',
                    style: const TextStyle(
                      fontSize: 27,
                      fontWeight: FontWeight.bold,
                      color: Colors.lightGreenAccent,
                    ),
                  )
                else if (pixelError != null)
                  Text(pixelError!, style: const TextStyle(color: Colors.orangeAccent))
                else
                  const Text('Bir noktaya dokunarak mesafeyi sorgula.'),
                if (selectedPixelX != null && selectedPixelY != null) ...[
                  const SizedBox(height: 7),
                  Text(
                    'Piksel: x=$selectedPixelX, y=$selectedPixelY',
                    style: const TextStyle(color: Colors.white60),
                  ),
                ],
                const SizedBox(height: 8),
                const Text(
                  'Uyari: Bu deger sensor olcumu degil, tek RGB goruntuden '
                  'model tahminidir. Kalibrasyon olmadan mutlak mesafe '
                  'hatasi olabilir. Merkezden dogrudan 3B mesafe degil, '
                  'goruntunun derinlik degeridir.',
                  style: TextStyle(fontSize: 12, color: Colors.white54),
                ),
              ],
            ),
          ),
        ],

        const SizedBox(height: 24),

        // SONUC OZETI
        appCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Sonuc Ozeti',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 16),
              infoTile(
                'Secilen Dosya',
                fileName ?? 'Dosya secilmedi',
                Icons.insert_drive_file_outlined,
              ),
              const SizedBox(height: 10),
              infoTile(
                'Kullanilan Model',
                'YOLO26n-Depth (pretrained)',
                Icons.memory_outlined,
              ),
              const SizedBox(height: 10),
              infoTile(
                'Analiz Durumu',
                (depthImageBytes != null || depthVideoController != null)
                    ? 'Basarili'
                    : analysisError != null
                        ? 'Hata'
                        : 'Henuz analiz yapilmadi',
                Icons.hourglass_empty,
              ),
              if (processedFrames != null) ...[
                const SizedBox(height: 10),
                infoTile('Islenen Video Karesi',
                    '$processedFrames kare / ${resultFps?.toStringAsFixed(1)} FPS',
                    Icons.movie_filter_outlined),
              ],
              const SizedBox(height: 10),
              infoTile(
                'Toplam Islem Suresi',
                analysisTimeMs != null
                    ? '${(analysisTimeMs! / 1000).toStringAsFixed(2)} sn'
                    : 'Henuz olculmedi',
                Icons.timer_outlined,
              ),
            ],
          ),
        ),

        const SizedBox(height: 20),
        paletteCard(),

        const SizedBox(height: 20),
        downloadCard(),

        const SizedBox(height: 22),

        OutlinedButton.icon(
          onPressed: () => changePage(0),
          icon: const Icon(Icons.arrow_back),
          label: const Text('Analiz Ekranina Don'),
        ),
      ],
    );
  }

  // ANA UYGULAMA EKRANI
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: const Color(0xFF1B2B43),
        title: const Row(
          children: [
            Icon(
              Icons.visibility_outlined,
              color: Colors.lightBlueAccent,
            ),
            SizedBox(width: 10),
            Text(
              'DepthLab',
              style: TextStyle(
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
      ),

      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(
                maxWidth: 1100,
              ),
              child: Padding(
                padding: const EdgeInsets.only(
                  bottom: 25,
                ),
                child: selectedPage == 0 ? analysisPage() : resultsPage(),
              ),
            ),
          ),
        ),
      ),

      // ALT NAVIGASYON
      bottomNavigationBar: NavigationBar(
        backgroundColor: const Color(0xFF17243A),
        selectedIndex: selectedPage,
        onDestinationSelected: changePage,
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.upload_file_outlined),
            selectedIcon: Icon(Icons.upload_file),
            label: 'Analiz',
          ),
          NavigationDestination(
            icon: Icon(Icons.analytics_outlined),
            selectedIcon: Icon(Icons.analytics),
            label: 'Sonuclar',
          ),
        ],
      ),
    );
  }
}


// KAMERA SAYFASI: Web/Android/iOS'ta canli goruntu ve fotograf cekimi.
class DepthCameraPage extends StatefulWidget {
  final CameraDescription camera;
  const DepthCameraPage({super.key, required this.camera});

  @override
  State<DepthCameraPage> createState() => _DepthCameraPageState();
}

class _DepthCameraPageState extends State<DepthCameraPage> {
  late final CameraController controller;
  late final Future<void> initFuture;
  bool takingPhoto = false;

  @override
  void initState() {
    super.initState();
    controller = CameraController(
      widget.camera,
      ResolutionPreset.medium,
      enableAudio: false,
    );
    initFuture = controller.initialize();
  }

  Future<void> capture() async {
    if (takingPhoto) return;
    setState(() => takingPhoto = true);
    try {
      await initFuture;
      final file = await controller.takePicture();
      if (!mounted) return;
      Navigator.of(context).pop<XFile>(file);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Fotograf cekilemedi: $e')),
      );
    } finally {
      if (mounted) setState(() => takingPhoto = false);
    }
  }

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Kameradan Fotograf Cek')),
      body: FutureBuilder<void>(
        future: initFuture,
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Text('Kamera izni veya baglantisi hatasi: ${snapshot.error}'),
              ),
            );
          }
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          return Column(
            children: [
              Expanded(
                child: Center(
                  child: AspectRatio(
                    aspectRatio: controller.value.aspectRatio,
                    child: CameraPreview(controller),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(20),
                child: FilledButton.icon(
                  onPressed: takingPhoto ? null : capture,
                  icon: const Icon(Icons.camera_alt),
                  label: Text(takingPhoto ? 'Cekiliyor...' : 'Fotograf Cek'),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

// CANLIYA YAKIN MESAFE MODU - FlutLab Web uyumlu.
// Web kamera paketi ham frame stream desteklemedigi icin otomatik snapshot
// alir; kullanicidan Analiz Et butonuna basmasini istemez.
// Olcum dokunulan ISLENMIS RGB KARESI uzerindedir; kamera onizlemesinin
// anlik bir karesi oldugu iddia edilmez.
class LiveDepthCameraPage extends StatefulWidget {
  final CameraDescription camera;
  final String apiBaseUrl;

  const LiveDepthCameraPage({
    super.key,
    required this.camera,
    required this.apiBaseUrl,
  });

  @override
  State<LiveDepthCameraPage> createState() => _LiveDepthCameraPageState();
}

class _LiveDepthCameraPageState extends State<LiveDepthCameraPage> {
  late final CameraController _controller;
  late final Future<void> _initializeCamera;

  bool _active = true;
  bool _showDepth = true;
  double _depthOpacity = 0.55;
  bool _processing = false;
  String? _error;

  Uint8List? _lastRgb;
  Uint8List? _lastDepth;
  int? _imageWidth;
  int? _imageHeight;
  int _sampleCount = 0;
  DateTime? _lastCompletedAt;
  int? _lastProcessingMs;

  // 0..1 normalized coordinates selected on the processed camera frame.
  double? _selectedU;
  double? _selectedV;
  double? _selectedMeters;
  int? _measurementFrame;
  bool _measurementValid = false;

  @override
  void initState() {
    super.initState();
    _controller = CameraController(
      widget.camera,
      ResolutionPreset.medium,
      enableAudio: false,
    );
    _initializeCamera = _controller.initialize();
    _initializeCamera.then((_) {
      if (mounted && _active) {
        unawaited(_autoAnalyze());
      }
    }).catchError((Object error) {
      if (mounted) {
        setState(() => _error = 'Kamera baslatilamadi: $error');
      }
    });
  }

  Future<void> _autoAnalyze() async {
    // Istekler ard arda, asla paralel gonderilmez.
    // CPU'daki inference hizina gore guncellenir.
    while (mounted && _active) {
      final watch = Stopwatch()..start();
      if (mounted) setState(() => _processing = true);
      try {
        final picture = await _controller.takePicture();
        if (!mounted || !_active) break;
        final capturedBytes = await picture.readAsBytes();
        if (!mounted || !_active) break;

        // Nokta, bu frame icin talep gonderilirken secilen noktadir.
        final requestedU = _selectedU;
        final requestedV = _selectedV;
        final request = http.MultipartRequest(
          'POST',
          Uri.parse('${widget.apiBaseUrl}/predict-live'),
        );
        request.files.add(
          http.MultipartFile.fromBytes(
            'file',
            capturedBytes,
            filename: 'live_frame.jpg',
          ),
        );
        if (requestedU != null && requestedV != null) {
          request.fields['u'] = requestedU.toStringAsFixed(8);
          request.fields['v'] = requestedV.toStringAsFixed(8);
        }

        final stream = await request.send().timeout(const Duration(seconds: 90));
        final response = await http.Response.fromStream(stream)
            .timeout(const Duration(seconds: 90));
        if (response.statusCode != 200) {
          throw Exception('HTTP ${response.statusCode}: ${response.body}');
        }

        final data = jsonDecode(response.body) as Map<String, dynamic>;
        final rgbBytes = base64Decode(data['rgb_jpg_b64'] as String);
        final depthBytes = base64Decode(data['depth_png_b64'] as String);
        final width = (data['width'] as num).toInt();
        final height = (data['height'] as num).toInt();
        if (width <= 0 || height <= 0) {
          throw Exception('Sunucu hatali goruntu boyutu dondurdu.');
        }
        watch.stop();
        if (!mounted || !_active) break;

        setState(() {
          _lastRgb = rgbBytes;
          _lastDepth = depthBytes;
          _imageWidth = width;
          _imageHeight = height;
          _sampleCount++;
          _lastCompletedAt = DateTime.now();
          _lastProcessingMs = watch.elapsedMilliseconds;
          _error = null;
          if (requestedU != null && requestedV != null &&
              requestedU == _selectedU && requestedV == _selectedV) {
            _measurementValid = data['valid'] == true;
            _selectedMeters = _measurementValid
                ? (data['depth_m'] as num?)?.toDouble()
                : null;
            _measurementFrame = _sampleCount;
          } else {
            // Dokunma istegi islem sirasinda degisti; eski metriği gosterme.
            _selectedMeters = null;
            _measurementFrame = null;
          }
        });
      } catch (error) {
        if (mounted && _active) {
          setState(() => _error = '$error');
        }
        // Bir hata durumunda kameraya arka arkaya istek yagma.
        await Future<void>.delayed(const Duration(seconds: 2));
      } finally {
        if (mounted) setState(() => _processing = false);
      }
      if (!mounted || !_active) break;
      await Future<void>.delayed(const Duration(milliseconds: 450));
    }
  }

  void _pickMeasurementPoint(Offset point, Size box) {
    final iw = _imageWidth;
    final ih = _imageHeight;
    if (iw == null || ih == null) return;
    final size = Size(iw.toDouble(), ih.toDouble());
    final fitted = applyBoxFit(BoxFit.contain, size, box);
    final rect = Rect.fromCenter(
      center: Offset(box.width / 2, box.height / 2),
      width: fitted.destination.width,
      height: fitted.destination.height,
    );
    if (!rect.contains(point)) return;
    final u = ((point.dx - rect.left) / rect.width).clamp(0.0, 1.0).toDouble();
    final v = ((point.dy - rect.top) / rect.height).clamp(0.0, 1.0).toDouble();
    setState(() {
      _selectedU = u;
      _selectedV = v;
      _selectedMeters = null;
      _measurementValid = false;
      _measurementFrame = null;
    });
  }

  Widget _analyzedFrame() {
    final rgb = _lastRgb;
    final depth = _lastDepth;
    final iw = _imageWidth;
    final ih = _imageHeight;
    if (rgb == null || depth == null || iw == null || ih == null) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'Kameradan ilk kare otomatik analiz ediliyor...\n'
            'Ilk goruntu geldiginde istedigin noktaya dokun.',
            textAlign: TextAlign.center,
          ),
        ),
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final box = Size(constraints.maxWidth, constraints.maxHeight);
        final fitted = applyBoxFit(
          BoxFit.contain,
          Size(iw.toDouble(), ih.toDouble()),
          box,
        );
        final rect = Rect.fromCenter(
          center: Offset(box.width / 2, box.height / 2),
          width: fitted.destination.width,
          height: fitted.destination.height,
        );
        final marker = _selectedU == null || _selectedV == null
            ? null
            : Offset(
                rect.left + _selectedU! * rect.width,
                rect.top + _selectedV! * rect.height,
              );

        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (detail) => _pickMeasurementPoint(detail.localPosition, box),
          child: Stack(
            fit: StackFit.expand,
            children: [
              Image.memory(rgb, fit: BoxFit.contain),
              if (_showDepth)
                Opacity(
                  opacity: _depthOpacity,
                  child: Image.memory(depth, fit: BoxFit.contain),
                ),
              if (marker != null)
                Positioned(
                  left: marker.dx - 12,
                  top: marker.dy - 12,
                  child: IgnorePointer(
                    child: Container(
                      height: 24,
                      width: 24,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: Colors.redAccent.withOpacity(0.75),
                        border: Border.all(color: Colors.white, width: 2.5),
                      ),
                      child: const Icon(Icons.add, color: Colors.white, size: 16),
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  Widget _panel({required String title, required Widget child}) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF1B2B43),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.blueGrey.shade700),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
          const SizedBox(height: 12),
          AspectRatio(
            aspectRatio: 4 / 3,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: ColoredBox(color: const Color(0xFF0C1728), child: child),
            ),
          ),
        ],
      ),
    );
  }

  Widget _livePreview() {
    // Kamera goruntusu surekli oynar. Kesin piksel olcumu sagdaki
    // islenmis snapshot panelinde gerceklestirilir.
    return Center(
      child: AspectRatio(
        aspectRatio: _controller.value.aspectRatio,
        child: CameraPreview(_controller),
      ),
    );
  }

  String _elapsedText() {
    if (_lastProcessingMs == null) return '-';
    return '${(_lastProcessingMs! / 1000).toStringAsFixed(1)} sn';
  }

  String _lastUpdateText() {
    final time = _lastCompletedAt;
    if (time == null) return '-';
    final hour = time.hour.toString().padLeft(2, '0');
    final minute = time.minute.toString().padLeft(2, '0');
    final second = time.second.toString().padLeft(2, '0');
    return '$hour:$minute:$second';
  }

  @override
  void dispose() {
    _active = false;
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: const Color(0xFF1B2B43),
        title: const Text('Canli Mesafe Olc'),
      ),
      body: FutureBuilder<void>(
        future: _initializeCamera,
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return Center(child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text('Kamera izni veya baslatma hatasi: ${snapshot.error}'),
            ));
          }
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }

          return SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 1100),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Kamera acilir acilmaz analiz baslar. Analiz Et butonuna gerek yok.',
                      style: TextStyle(fontSize: 15, color: Colors.white70),
                    ),
                    const SizedBox(height: 10),
                    const Text(
                      'Solda canli kamera, sagda son islenen kare vardir. '
                      'Mesafe olcmek icin islenmis kareye dokun. '
                      'Model sunucuda calistigi icin olcumler gecikmeli guncellenir.',
                      style: TextStyle(color: Colors.orangeAccent),
                    ),
                    const SizedBox(height: 16),
                    LayoutBuilder(builder: (context, limits) {
                      final live = _panel(
                        title: 'Canli Kamera (Onizleme)',
                        child: _livePreview(),
                      );
                      final analyzed = _panel(
                        title: 'Islenen Kare - Dokun ve Olc',
                        child: _analyzedFrame(),
                      );
                      if (limits.maxWidth < 740) {
                        return Column(children: [
                          live,
                          const SizedBox(height: 14),
                          analyzed,
                        ]);
                      }
                      return Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(child: live),
                          const SizedBox(width: 14),
                          Expanded(child: analyzed),
                        ],
                      );
                    }),
                    const SizedBox(height: 16),
                    Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: const Color(0xFF1B2B43),
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(children: [
                            Icon(
                              _error != null ? Icons.error_outline : Icons.sync,
                              color: _error != null ? Colors.orangeAccent : Colors.lightBlueAccent,
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                _error != null
                                    ? 'Analiz hatasi (otomatik yeniden deneniyor)'
                                    : _processing
                                        ? 'Kamera karesi analiz ediliyor...'
                                        : 'Analiz calisiyor',
                                style: const TextStyle(fontWeight: FontWeight.bold),
                              ),
                            ),
                          ]),
                          if (_processing) ...[
                            const SizedBox(height: 8),
                            const LinearProgressIndicator(),
                          ],
                          if (_error != null) ...[
                            const SizedBox(height: 8),
                            Text(_error!, style: const TextStyle(color: Colors.orangeAccent)),
                          ],
                          const SizedBox(height: 12),
                          if (_selectedU == null)
                            const Text(
                              'Olcumu baslatmak icin islenmis goruntude bir noktaya dokun.',
                              style: TextStyle(color: Colors.white70),
                            )
                          else if (_selectedMeters != null && _measurementFrame == _sampleCount)
                            Text(
                              'Tahmini derinlik: ${_selectedMeters!.toStringAsFixed(2)} m',
                              style: const TextStyle(
                                fontSize: 27,
                                color: Colors.lightGreenAccent,
                                fontWeight: FontWeight.bold,
                              ),
                            )
                          else if (_measurementFrame == _sampleCount && !_measurementValid)
                            const Text('Bu noktada gecerli derinlik tahmini yok.')
                          else
                            const Text('Secilen nokta bir sonraki karede olculecek...'),
                          const SizedBox(height: 8),
                          Text(
                            'Analiz edilen kare: $_sampleCount | '
                            'Son analiz: ${_elapsedText()} | '
                            'Guncelleme: ${_lastUpdateText()}',
                            style: const TextStyle(color: Colors.white60, fontSize: 12),
                          ),
                          const SizedBox(height: 12),
                          Row(children: [
                            Switch.adaptive(
                              value: _showDepth,
                              onChanged: (value) => setState(() => _showDepth = value),
                            ),
                            const Expanded(child: Text('Depth overlay')),
                            Text('${(_depthOpacity * 100).round()}%'),
                          ]),
                          Slider(
                            value: _depthOpacity,
                            min: 0,
                            max: 1,
                            divisions: 20,
                            onChanged: _showDepth
                                ? (value) => setState(() => _depthOpacity = value)
                                : null,
                          ),
                          const Text(
                            'Uyari: Sonuc YOLO26-Depth tahminidir, sensor olcumu degildir. '
                            'Kamera hareket ederse islenmis kare ile anlik onizleme farkli olabilir.',
                            style: TextStyle(color: Colors.white54, fontSize: 12),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}



// GROUND TRUTH KARSILASTIRMA SAYFASI
// Depth8: Ayni isimli JPG (RGB) + 16-bit PNG (sensor derinligi) secilir.
// Mevcut fotograf/video/canli kamera akisini degistirmez.
class GroundTruthTestPage extends StatefulWidget {
  const GroundTruthTestPage({super.key});

  @override
  State<GroundTruthTestPage> createState() => _GroundTruthTestPageState();
}

class _GroundTruthTestPageState extends State<GroundTruthTestPage> {
  static const String _apiBaseUrl = 'http://127.0.0.1:8000';
  final ImagePicker _picker = ImagePicker();
  XFile? _rgbFile;
  XFile? _gtFile;
  Uint8List? _rgbBytes;
  Uint8List? _predictionPreview;
  Uint8List? _groundTruthPreview;
  Uint8List? _errorPreview;
  Map<String, dynamic>? _metrics;
  String? _evaluationId;
  String? _error;
  bool _busy = false;
  bool _pointBusy = false;
  Map<String, dynamic>? _pointInfo;
  int? _pixelX;
  int? _pixelY;
  int? _width;
  int? _height;

  String _stem(String filename) {
    final name = filename.split(RegExp(r'[/\\]')).last;
    final index = name.lastIndexOf('.');
    return (index > 0 ? name.substring(0, index) : name).toLowerCase();
  }

  bool get _hasPairedNames =>
      _rgbFile != null && _gtFile != null &&
      _stem(_rgbFile!.name) == _stem(_gtFile!.name);

  void _resetResult() {
    _predictionPreview = null;
    _groundTruthPreview = null;
    _errorPreview = null;
    _metrics = null;
    _evaluationId = null;
    _pointInfo = null;
    _pixelX = null;
    _pixelY = null;
    _width = null;
    _height = null;
    _error = null;
  }

  Future<void> _chooseRgb() async {
    if (_busy) return;
    try {
      final chosen = await _picker.pickImage(source: ImageSource.gallery);
      if (chosen == null) return;
      final raw = await chosen.readAsBytes();
      if (!mounted) return;
      setState(() {
        _rgbFile = chosen;
        _rgbBytes = raw;
        _resetResult();
      });
    } catch (e) {
      if (mounted) setState(() => _error = 'RGB secilemedi: $e');
    }
  }

  Future<void> _chooseGt() async {
    if (_busy) return;
    try {
      final chosen = await _picker.pickImage(source: ImageSource.gallery);
      if (chosen == null) return;
      final raw = await chosen.readAsBytes();
      if (!mounted) return;
      if (!chosen.name.toLowerCase().endsWith('.png')) {
        setState(() => _error = 'Ground Truth dosyasi PNG olmali.');
        return;
      }
      // Dosyayi donusturmuyoruz. 16-bit kontrolu sunucuda yapiliyor.
      if (raw.length > 12 * 1024 * 1024) {
        setState(() => _error = 'GT dosyasi 12 MB sinirini asti.');
        return;
      }
      setState(() {
        _gtFile = chosen;
        _resetResult();
      });
    } catch (e) {
      if (mounted) setState(() => _error = 'GT secilemedi: $e');
    }
  }

  Future<void> _evaluate() async {
    if (_busy || _rgbBytes == null || _gtFile == null) return;
    if (!_hasPairedNames) {
      setState(() => _error =
          'RGB ve GT dosyalari ayni temel isme sahip olmali. '
          'Ornek: kv1_NYUdata_NYU0451.jpg ve .png');
      return;
    }
    setState(() {
      _busy = true;
      _resetResult();
    });
    try {
      final gtBytes = await _gtFile!.readAsBytes();
      if (_rgbBytes!.length > 12 * 1024 * 1024 ||
          gtBytes.length > 12 * 1024 * 1024) {
        throw Exception('Her dosya en fazla 12 MB olabilir.');
      }
      final request = http.MultipartRequest(
        'POST',
        Uri.parse('$_apiBaseUrl/evaluate-depth'),
      );
      request.files.add(http.MultipartFile.fromBytes(
        'rgb',
        _rgbBytes!,
        filename: _rgbFile!.name,
      ));
      request.files.add(http.MultipartFile.fromBytes(
        'ground_truth',
        gtBytes,
        filename: _gtFile!.name,
      ));
      final streamed = await request.send().timeout(const Duration(minutes: 4));
      final response = await http.Response.fromStream(streamed);
      if (response.statusCode != 200) {
        String explanation = response.body;
        try {
          final parsed = jsonDecode(response.body) as Map<String, dynamic>;
          explanation = parsed['detail']?.toString() ?? response.body;
        } catch (_) {}
        throw Exception('Sunucu HTTP ${response.statusCode}: $explanation');
      }
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      if (!mounted) return;
      setState(() {
        _predictionPreview = base64Decode(data['prediction_png_b64'] as String);
        _groundTruthPreview = base64Decode(data['ground_truth_png_b64'] as String);
        _errorPreview = base64Decode(data['error_png_b64'] as String);
        _metrics = data;
        _evaluationId = data['evaluation_id'] as String;
        _width = (data['width'] as num).toInt();
        _height = (data['height'] as num).toInt();
      });
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _inspectPixel(Offset location, Size box) async {
    final id = _evaluationId;
    final w = _width;
    final h = _height;
    if (id == null || w == null || h == null || _pointBusy) return;
    final fit = applyBoxFit(
      BoxFit.contain, Size(w.toDouble(), h.toDouble()), box);
    final dest = fit.destination;
    final rect = Rect.fromLTWH(
      (box.width - dest.width) / 2,
      (box.height - dest.height) / 2,
      dest.width, dest.height,
    );
    if (!rect.contains(location)) return;
    final x = (((location.dx - rect.left) / rect.width) * w)
        .floor().clamp(0, w - 1).toInt();
    final y = (((location.dy - rect.top) / rect.height) * h)
        .floor().clamp(0, h - 1).toInt();
    setState(() {
      _pixelX = x;
      _pixelY = y;
      _pointBusy = true;
      _pointInfo = null;
    });
    try {
      final uri = Uri.parse('$_apiBaseUrl/evaluation-at/$id').replace(
        queryParameters: {'x': '$x', 'y': '$y'},
      );
      final response = await http.get(uri).timeout(const Duration(seconds: 15));
      if (response.statusCode != 200) {
        throw Exception('Piksel sorgusu: HTTP ${response.statusCode}');
      }
      final parsed = jsonDecode(response.body) as Map<String, dynamic>;
      if (!mounted || id != _evaluationId || x != _pixelX || y != _pixelY) return;
      setState(() => _pointInfo = parsed);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _pointBusy = false);
    }
  }

  Widget _card({required Widget child}) => Card(
    color: const Color(0xFF1B2B43),
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
    child: Padding(padding: const EdgeInsets.all(16), child: child),
  );

  Widget _photoPanel(String title, Uint8List bytes, double panelWidth, {
    bool tappable = true,
  }) {
    return SizedBox(
      width: panelWidth,
      child: _card(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: const TextStyle(
              fontSize: 16, fontWeight: FontWeight.bold,
            )),
            const SizedBox(height: 10),
            SizedBox(
              height: 260,
              width: double.infinity,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(9),
                child: ColoredBox(
                  color: const Color(0xFF0C1728),
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final box = Size(constraints.maxWidth, constraints.maxHeight);
                      Offset? marker;
                      if (tappable && _pixelX != null && _pixelY != null &&
                          _width != null && _height != null) {
                        final fitted = applyBoxFit(
                          BoxFit.contain,
                          Size(_width!.toDouble(), _height!.toDouble()), box,
                        );
                        marker = Offset(
                          (box.width - fitted.destination.width) / 2 +
                            ((_pixelX! + 0.5) / _width!) * fitted.destination.width,
                          (box.height - fitted.destination.height) / 2 +
                            ((_pixelY! + 0.5) / _height!) * fitted.destination.height,
                        );
                      }
                      return GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTapDown: tappable && _evaluationId != null
                            ? (details) => _inspectPixel(details.localPosition, box)
                            : null,
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            Image.memory(bytes, fit: BoxFit.contain),
                            if (marker != null)
                              Positioned(
                                left: marker.dx - 8,
                                top: marker.dy - 8,
                                child: IgnorePointer(
                                  child: Container(
                                    width: 16,
                                    height: 16,
                                    decoration: BoxDecoration(
                                      shape: BoxShape.circle,
                                      color: Colors.redAccent,
                                      border: Border.all(color: Colors.white, width: 2),
                                    ),
                                  ),
                                ),
                              ),
                          ],
                        ),
                      );
                    },
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _metricTile(String title, String value, String description, double width) {
    return SizedBox(
      width: width,
      child: _card(child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: const TextStyle(color: Colors.white70)),
          const SizedBox(height: 7),
          Text(value, style: const TextStyle(
            fontSize: 23,
            fontWeight: FontWeight.bold,
            color: Colors.lightGreenAccent,
          )),
          const SizedBox(height: 4),
          Text(description, style: const TextStyle(
            fontSize: 12, color: Colors.white60,
          )),
        ],
      )),
    );
  }

  String _num(String key, int decimals) =>
      ((_metrics?[key] as num?)?.toDouble() ?? 0).toStringAsFixed(decimals);

  @override
  Widget build(BuildContext context) {
    final done = _metrics != null &&
        _rgbBytes != null &&
        _predictionPreview != null &&
        _groundTruthPreview != null &&
        _errorPreview != null;

    return Scaffold(
      appBar: AppBar(
        backgroundColor: const Color(0xFF1B2B43),
        title: const Text('DepthLab | GT ile Test'),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 1100),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Ground Truth Karsilastirmasi', style: TextStyle(
                    fontSize: 26, fontWeight: FontWeight.bold,
                  )),
                  const SizedBox(height: 9),
                  const Text(
                    'Depth8: Ayni sahnenin RGB fotografindan YOLO26n-Depth '
                    'tahmini alinip sensor Ground Truth verisi ile karsilastirilir.',
                    style: TextStyle(color: Colors.white70),
                  ),
                  const SizedBox(height: 14),
                  _card(child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Wrap(spacing: 10, runSpacing: 10, children: [
                        OutlinedButton.icon(
                          onPressed: _busy ? null : _chooseRgb,
                          icon: const Icon(Icons.add_photo_alternate),
                          label: const Text('RGB Fotograf Sec'),
                        ),
                        OutlinedButton.icon(
                          onPressed: _busy ? null : _chooseGt,
                          icon: const Icon(Icons.layers_outlined),
                          label: const Text('Gercek GT PNG Sec'),
                        ),
                        FilledButton.icon(
                          onPressed: _busy || _rgbBytes == null || _gtFile == null
                              ? null : _evaluate,
                          icon: const Icon(Icons.analytics_outlined),
                          label: const Text('GT ile Karsilastir'),
                        ),
                      ]),
                      const SizedBox(height: 12),
                      Text('RGB: ${_rgbFile?.name ?? "Secilmedi"}',
                          style: const TextStyle(fontSize: 13)),
                      const SizedBox(height: 5),
                      Text('Gercek GT: ${_gtFile?.name ?? "Secilmedi"}',
                          style: const TextStyle(fontSize: 13)),
                      if (_rgbFile != null && _gtFile != null && !_hasPairedNames) ...[
                        const SizedBox(height: 10),
                        const Text('Dosya adlari ayni olmali: '
                            'ornek.jpg ve ornek.png',
                            style: TextStyle(color: Colors.orangeAccent)),
                      ],
                      const SizedBox(height: 10),
                      const Text('RGB dosyasi: images/val klasorunden JPG. '
                          'GT dosyasi: depth/val klasorunden ayni adli 16-bit PNG. '
                          'GT olcegi: 1000 birim = 1 m.',
                          style: TextStyle(fontSize: 12, color: Colors.white60)),
                      if (_busy) ...[
                        const SizedBox(height: 12),
                        const LinearProgressIndicator(),
                        const SizedBox(height: 7),
                        const Text('Model tahmini ve metrikler hesaplaniyor...'),
                      ],
                      if (_error != null) ...[
                        const SizedBox(height: 12),
                        SelectableText(_error!,
                            style: const TextStyle(color: Colors.orangeAccent)),
                      ],
                    ],
                  )),
                  if (done) ...[
                    const SizedBox(height: 18),
                    const Text('Dogruluk Metrikleri', style: TextStyle(
                      fontSize: 21, fontWeight: FontWeight.bold,
                    )),
                    const SizedBox(height: 8),
                    LayoutBuilder(builder: (context, constraints) {
                      final w = constraints.maxWidth;
                      final tileWidth = w >= 760 ? (w - 36) / 4 :
                          w >= 430 ? (w - 12) / 2 : w;
                      return Wrap(spacing: 12, runSpacing: 12, children: [
                        _metricTile('MAE', '${_num('mae_m', 3)} m',
                            'Ortalama mutlak hata - dusuk iyi', tileWidth),
                        _metricTile('RMSE', '${_num('rmse_m', 3)} m',
                            'Buyuk hatalari daha fazla cezalandirir', tileWidth),
                        _metricTile('AbsRel', _num('absrel', 4),
                            'Ortalama goreli hata - dusuk iyi', tileWidth),
                        _metricTile('Delta1', '${(_metrics!['delta1'] as num).toDouble().toStringAsFixed(2)}%',
                            '1.25 esiginde dogru oran - yuksek iyi', tileWidth),
                      ]);
                    }),
                    const SizedBox(height: 12),
                    _card(child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('GT gecerli piksel: ${_num('gt_valid_percent', 2)}%'
                            ' | Degerlendirilen GT pikselleri: '
                            '${_num('evaluated_gt_percent', 2)}%'),
                        const SizedBox(height: 4),
                        Text('GT uzerinde gecersiz model tahmini: '
                            '${_num('invalid_prediction_percent', 2)}%'),
                        const SizedBox(height: 4),
                        Text('Goruntu: $_width x $_height'
                            ' | Degerlendirilen piksel: ${_metrics!['evaluated_pixels']}'),
                        const SizedBox(height: 9),
                        Text('RGB, tahmin ve GT haritalarinda geometri ayni. '
                            'Tahmin ile GT haritalari AYNI 0-${_num('display_max_m', 2)} m '
                            'renk olcegini kullaniyor.'),
                        const SizedBox(height: 6),
                        Text('Mutlak hata haritasi 0-${_num('error_display_max_m', 2)} m '
                            'araliginda renklendirildi. Daha buyuk hatalar en ust '
                            'renkle gosterilir.',
                            style: const TextStyle(fontSize: 12, color: Colors.white70)),
                      ],
                    )),
                    const SizedBox(height: 18),
                    const Text('Gorsel Karsilastirma', style: TextStyle(
                      fontSize: 21, fontWeight: FontWeight.bold,
                    )),
                    const SizedBox(height: 8),
                    LayoutBuilder(builder: (context, constraints) {
                      final w = constraints.maxWidth;
                      final half = w >= 700 ? (w - 12) / 2 : w;
                      return Wrap(spacing: 12, runSpacing: 12, children: [
                        _photoPanel('1. RGB - Orijinal', _rgbBytes!, half),
                        _photoPanel('2. YOLO Tahmini', _predictionPreview!, half),
                        _photoPanel('3. Ground Truth', _groundTruthPreview!, half),
                        _photoPanel('4. Mutlak Hata (metre)', _errorPreview!, half),
                      ]);
                    }),
                    const SizedBox(height: 12),
                    _card(child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('Piksel Bazli Karsilastirma', style: TextStyle(
                          fontSize: 17, fontWeight: FontWeight.bold,
                        )),
                        const SizedBox(height: 7),
                        const Text('Yukaridaki goruntulerden bir noktaya tikla. '
                            'Model tahmini ile gercek GT degerini yan yana gosterelim.'),
                        const SizedBox(height: 9),
                        if (_pointBusy)
                          const LinearProgressIndicator()
                        else if (_pointInfo == null)
                          const Text('Henuz piksel secilmedi.',
                              style: TextStyle(color: Colors.white60))
                        else if (_pointInfo!['valid'] != true)
                          Text('Piksel: x=$_pixelX, y=$_pixelY | '
                               'Gecerli tahmin/GT eslesmesi yok.',
                               style: const TextStyle(color: Colors.orangeAccent))
                        else ...[
                          Text('Secilen piksel: x=$_pixelX, y=$_pixelY'),
                          const SizedBox(height: 5),
                          Text('YOLO: ${(_pointInfo!['pred_m'] as num).toStringAsFixed(3)} m'
                               '   |   GT: ${(_pointInfo!['gt_m'] as num).toStringAsFixed(3)} m'
                               '   |   Hata: ${(_pointInfo!['abs_error_m'] as num).toStringAsFixed(3)} m',
                               style: const TextStyle(fontSize: 16,
                                   color: Colors.lightGreenAccent)),
                        ],
                      ],
                    )),
                    const SizedBox(height: 12),
                    const Text(
                      'Not: Modelin ciktisi metre cinsinden tahmindir; kesin olcum degildir. '
                      'Depth8 cok kucuk bir veri setidir ve bagimsiz akademik '
                      'basari iddiasi icin uygun olmayabilir.',
                      style: TextStyle(color: Colors.white60, fontSize: 12),
                    ),
                  ],
                  const SizedBox(height: 30),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
