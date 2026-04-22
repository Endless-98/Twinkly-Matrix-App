import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:file_picker/file_picker.dart';
import 'dart:async';
import 'dart:io' as io;import '../services/api_service.dart';
import '../providers/app_state.dart';
import '../widgets/video_editor_dialog.dart';
import '../widgets/rendered_video_trimmer_dialog.dart';
import 'schedules_page.dart';

class ScenesSelectorPage extends ConsumerStatefulWidget {
  const ScenesSelectorPage({super.key});

  @override
  ConsumerState<ScenesSelectorPage> createState() => _ScenesSelectorPageState();
}

class _ScenesSelectorPageState extends ConsumerState<ScenesSelectorPage> {
  List<String> _scenes = [];
  bool _isLoading = true;
  String? _error;
  String? _currentlyPlaying;
  bool _isLooping = true;
  double _brightness = 1.0;
  final double _playbackFps = 20.0;

  // Folder state (was playlists)
  List<Map<String, dynamic>> _folders = [];
  String? _currentFolder; // null = root view, folder name = inside folder

  // Upload progress tracking
  final Map<String, double> _uploadProgress = {};
  final Set<String> _uploadingFiles = {};
  final Set<String> _renderingFiles = {};
  final Map<String, double> _renderProgress = {};
  final Map<String, int> _renderFramesCurrent = {};
  final Map<String, int> _renderFramesTotal = {};
  Timer? _renderCheckTimer;
  final ScrollController _scrollController = ScrollController();
  final Map<String, GlobalKey> _itemKeys = {};
  String? _pendingHighlight;
  String? _activeHighlight;
  Timer? _highlightTimer;
  Timer? _previewDebounce;

  static const _transitions = [
    'none', 'fade', 'slide', 'slide_up', 'wipe',
    'dissolve', 'zoom', 'iris', 'fisheye_swirl',
  ];

  static const _folderColors = <String, Color>{
    '#42A5F5': Color(0xFF42A5F5), // Blue
    '#66BB6A': Color(0xFF66BB6A), // Green
    '#FFA726': Color(0xFFFFA726), // Orange
    '#EF5350': Color(0xFFEF5350), // Red
    '#AB47BC': Color(0xFFAB47BC), // Purple
    '#26C6DA': Color(0xFF26C6DA), // Cyan
    '#EC407A': Color(0xFFEC407A), // Pink
    '#FFEE58': Color(0xFFFFEE58), // Yellow
    '#8D6E63': Color(0xFF8D6E63), // Brown
    '#78909C': Color(0xFF78909C), // Blue Grey
  };

  Color _colorFromHex(String hex) {
    return _folderColors[hex] ?? const Color(0xFF42A5F5);
  }

  String _displayName(String filename) {
    final lastDot = filename.lastIndexOf('.');
    if (lastDot != -1 && lastDot < filename.length - 1) {
      return filename.substring(0, lastDot);
    }
    return filename;
  }

  @override
  void initState() {
    super.initState();
    _loadScenes();
  }

  @override
  void dispose() {
    _renderCheckTimer?.cancel();
    _highlightTimer?.cancel();
    _previewDebounce?.cancel();
    _scrollController.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------------------------
  // Data loading
  // ---------------------------------------------------------------------------

  Future<void> _loadScenes() async {
    final previousScenes = Set<String>.from(_scenes);
    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      final fppIp = ref.read(fppIpProvider);
      final apiService = ApiService(host: fppIp);
      final scenes = await apiService.getAvailableVideos();

      // Sync playback status
      try {
        final status = await apiService.getStatus();
        final playing = status['playing'] == true;
        final currentVideo = status['video'] as String?;
        if (mounted) {
          setState(() => _currentlyPlaying = playing ? currentVideo : null);
        }
      } catch (_) {}

      setState(() {
        _scenes = scenes;
        _isLoading = false;

        final newItems = scenes.where((s) => !previousScenes.contains(s)).toList();
        if (newItems.isNotEmpty) {
          _pendingHighlight ??= newItems.first;
        }

        if (_renderingFiles.isNotEmpty) {
          _startRenderCheckTimer();
        } else {
          _renderCheckTimer?.cancel();
          _renderCheckTimer = null;
        }
      });
      _scheduleHighlightScroll();

      // Load folders
      try {
        final folders = await apiService.getPlaylists();
        if (mounted) setState(() => _folders = folders);
      } catch (_) {}
    } catch (e) {
      setState(() {
        _error = e.toString();
        _isLoading = false;
      });
    }
  }

  void _startRenderCheckTimer() {
    if (_renderCheckTimer?.isActive ?? false) return;
    _renderCheckTimer = Timer.periodic(const Duration(seconds: 2), (_) async {
      if (_renderingFiles.isNotEmpty && mounted) {
        final fppIp = ref.read(fppIpProvider);
        final apiService = ApiService(host: fppIp);

        bool anyCompleted = false;
        for (final filename in _renderingFiles.toList()) {
          try {
            final progressData = await apiService.getRenderProgress(filename);
            if (mounted) {
              final progress = (progressData['progress'] as num?)?.toDouble() ?? 0.0;
              final status = progressData['status'] as String?;
              final framesRendered = (progressData['frames_rendered'] as num?)?.toInt() ?? 0;
              final totalFrames = (progressData['total_frames'] as num?)?.toInt() ?? 0;

              setState(() {
                _renderProgress[filename] = progress;
                _renderFramesCurrent[filename] = framesRendered;
                _renderFramesTotal[filename] = totalFrames;
              });

              if (status == 'complete' || status == 'error') {
                setState(() {
                  _renderingFiles.remove(filename);
                  _renderProgress.remove(filename);
                  _renderFramesCurrent.remove(filename);
                  _renderFramesTotal.remove(filename);
                });
                if (status == 'complete' && _pendingHighlight == null) {
                  _pendingHighlight = filename;
                }
                anyCompleted = true;
              }
            }
          } catch (_) {}
        }

        if (anyCompleted) await _loadScenes();
        if (_renderingFiles.isEmpty) {
          _renderCheckTimer?.cancel();
          _renderCheckTimer = null;
        }
      }
    });
  }

  void _scheduleHighlightScroll() {
    if (!mounted || _pendingHighlight == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToHighlight());
  }

  void _scrollToHighlight() {
    final target = _pendingHighlight;
    if (target == null) return;
    final key = _itemKeys[target];
    if (key?.currentContext == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToHighlight());
      return;
    }

    _pendingHighlight = null;
    _activeHighlight = target;
    _highlightTimer?.cancel();
    _highlightTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) setState(() => _activeHighlight = null);
    });

    Scrollable.ensureVisible(
      key!.currentContext!,
      alignment: 0.2,
      duration: const Duration(milliseconds: 500),
      curve: Curves.easeInOut,
    );
    setState(() {});
  }

  // ---------------------------------------------------------------------------
  // Playback
  // ---------------------------------------------------------------------------

  Future<void> _playScene(String sceneName) async {
    try {
      final fppIp = ref.read(fppIpProvider);
      final apiService = ApiService(host: fppIp);
      await apiService.playVideo(sceneName,
          loop: _isLooping, brightness: _brightness, playbackFps: _playbackFps);
      setState(() => _currentlyPlaying = sceneName);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Playing: ${_displayName(sceneName)}')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  Future<void> _stopPlayback() async {
    try {
      final fppIp = ref.read(fppIpProvider);
      final apiService = ApiService(host: fppIp);
      await apiService.stopPlayback();
      setState(() => _currentlyPlaying = null);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  Future<void> _updateBrightness(double brightness) async {
    try {
      final fppIp = ref.read(fppIpProvider);
      final apiService = ApiService(host: fppIp);
      await apiService.setBrightness(brightness);
    } catch (_) {}
  }

  // ---------------------------------------------------------------------------
  // Video CRUD
  // ---------------------------------------------------------------------------

  Future<void> _deleteVideo(String videoName) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Video'),
        content: Text('Delete "${_displayName(videoName)}"?\n\nThis cannot be undone.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    try {
      final fppIp = ref.read(fppIpProvider);
      final apiService = ApiService(host: fppIp);
      await apiService.deleteVideo(videoName);
      await _loadScenes();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Deleted ${_displayName(videoName)}'), backgroundColor: Colors.green),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  Future<void> _recolorVideo(String videoName) async {
    double brightness = 0.0;
    double contrast = 1.0;
    double hue = 0.0;
    double saturation = 1.0;

    final fppIp = ref.read(fppIpProvider);
    final apiService = ApiService(host: fppIp);

    void schedulePreview() {
      _previewDebounce?.cancel();
      _previewDebounce = Timer(const Duration(milliseconds: 300), () {
        apiService.previewRecolorVideo(videoName,
            brightness: brightness, contrast: contrast, hue: hue, saturation: saturation);
      });
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDlgState) => AlertDialog(
          title: Row(
            children: [
              const Icon(Icons.tune, size: 20, color: Colors.cyanAccent),
              const SizedBox(width: 8),
              Flexible(child: Text('Color Adjust: ${_displayName(videoName)}', overflow: TextOverflow.ellipsis)),
            ],
          ),
          content: SizedBox(
            width: double.maxFinite,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('Adjustments are non-destructive — original quality is preserved.',
                    style: TextStyle(fontSize: 11, color: Colors.grey), textAlign: TextAlign.center),
                const SizedBox(height: 16),
                _buildAdjustRow('Brightness', brightness, -100, 100, '${brightness.toStringAsFixed(0)}', (v) { setDlgState(() => brightness = v); schedulePreview(); }),
                _buildAdjustRow('Contrast', contrast, 0.5, 2.0, '${(contrast * 100).toStringAsFixed(0)}%', (v) { setDlgState(() => contrast = v); schedulePreview(); }),
                _buildAdjustRow('Hue', hue, -180, 180, '${hue.toStringAsFixed(0)}°', (v) { setDlgState(() => hue = v); schedulePreview(); }),
                _buildAdjustRow('Saturation', saturation, 0.0, 3.0, '${(saturation * 100).toStringAsFixed(0)}%', (v) { setDlgState(() => saturation = v); schedulePreview(); }),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () {
                setDlgState(() { brightness = 0; contrast = 1; hue = 0; saturation = 1; });
                schedulePreview();
              },
              child: const Text('Reset'),
            ),
            TextButton(onPressed: () { _previewDebounce?.cancel(); apiService.clearRecolorPreview(videoName); Navigator.pop(ctx, false); }, child: const Text('Cancel')),
            ElevatedButton(
              onPressed: () { _previewDebounce?.cancel(); apiService.clearRecolorPreview(videoName); Navigator.pop(ctx, true); },
              style: ElevatedButton.styleFrom(backgroundColor: Colors.cyanAccent, foregroundColor: Colors.black),
              child: const Text('Apply'),
            ),
          ],
        ),
      ),
    );

    if (confirmed != true) return;

    // Show processing indicator
    if (!mounted) return;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => const AlertDialog(
        title: Text('Applying Color Adjustments'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(),
            SizedBox(height: 16),
            Text('Processing... this may take a moment.', textAlign: TextAlign.center),
          ],
        ),
      ),
    );

    try {
      await apiService.recolorVideo(videoName,
          brightness: brightness, contrast: contrast, hue: hue, saturation: saturation);
      if (!mounted) return;
      Navigator.of(context).pop();
      // Bust image cache for this thumbnail
      final thumbUrl = apiService.getThumbnailUrl(videoName);
      PaintingBinding.instance.imageCache.evict(NetworkImage(thumbUrl));
      await _loadScenes();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Color adjusted: ${_displayName(videoName)}'), backgroundColor: Colors.green),
        );
      }
    } catch (e) {
      if (!mounted) return;
      Navigator.of(context).pop();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed: $e'), backgroundColor: Colors.red),
      );
    }
  }

  Widget _buildAdjustRow(String label, double value, double min, double max, String displayVal, ValueChanged<double> onChanged) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          SizedBox(width: 78, child: Text(label, style: const TextStyle(fontSize: 13))),
          Expanded(
            child: SliderTheme(
              data: SliderThemeData(
                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
                trackHeight: 3,
                activeTrackColor: Colors.cyanAccent.withValues(alpha: 0.7),
                thumbColor: Colors.cyanAccent,
                overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
              ),
              child: Slider(value: value, min: min, max: max, onChanged: onChanged),
            ),
          ),
          SizedBox(width: 48, child: Text(displayVal, textAlign: TextAlign.right, style: const TextStyle(fontSize: 11, color: Colors.grey))),
        ],
      ),
    );
  }

  Future<void> _trimVideo(String videoName) async {    if (!videoName.endsWith('.npz')) return;

    final fppIp = ref.read(fppIpProvider);
    final apiService = ApiService(host: fppIp);

    try {
      final metadata = await apiService.getRenderedVideoMeta(videoName);
      final duration = (metadata['duration'] as num).toDouble();
      final totalFrames = (metadata['frames'] as num).toInt();
      final fps = (metadata['fps'] as num).toDouble();

      if (!mounted) return;

      await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (context) => RenderedVideoTrimmerDialog(
          videoPath: '',
          fileName: videoName,
          duration: duration,
          totalFrames: totalFrames,
          fps: fps,
          apiHost: fppIp,
          onConfirm: (startTime, endTime, outputName) {
            _performTrim(videoName, startTime, endTime, outputName);
          },
        ),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to load metadata: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  Future<void> _performTrim(String videoName, double startTime, double endTime, String outputName) async {
    final fppIp = ref.read(fppIpProvider);
    final apiService = ApiService(host: fppIp);
    try {
      _pendingHighlight = outputName;
      await apiService.trimRenderedVideo(videoName,
          startTime: startTime, endTime: endTime, outputName: outputName);
      await _loadScenes();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Trimmed ${_displayName(videoName)}'), backgroundColor: Colors.green),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Trim failed: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  Future<void> _renameVideo(String videoName) async {
    String newName = _displayName(videoName);
    final controller = TextEditingController(text: newName);

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Rename Video'),
        content: TextField(
          controller: controller,
          onChanged: (v) => newName = v,
          decoration: InputDecoration(labelText: 'New name', hintText: _displayName(videoName)),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          ElevatedButton(onPressed: () => Navigator.pop(context, true), child: const Text('Rename')),
        ],
      ),
    );
    controller.dispose();
    if (confirmed != true || newName == _displayName(videoName)) return;

    try {
      final fppIp = ref.read(fppIpProvider);
      final apiService = ApiService(host: fppIp);
      await apiService.renameVideo(videoName, newName);
      await _loadScenes();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Renamed to $newName'), backgroundColor: Colors.green),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Rename failed: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  // ---------------------------------------------------------------------------
  // Upload / YouTube download
  // ---------------------------------------------------------------------------

  Future<void> _uploadAndRenderVideo() async {
    final choice = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Add Video'),
        content: const Text('How would you like to add a video?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, 'local'),
            child: const Text('Upload from Device'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, 'youtube'),
            child: const Text('Download from YouTube'),
          ),
        ],
      ),
    );
    if (choice == null) return;
    if (choice == 'local') {
      await _pickLocalVideo();
    } else {
      await _downloadYouTubeVideo();
    }
  }

  Future<void> _pickLocalVideo() async {
    try {
      final result = await FilePicker.platform.pickFiles(type: FileType.video, allowMultiple: false);
      if (result == null) return;

      final file = result.files.single;
      final fileName = file.name;
      final filePath = file.path;
      if (filePath == null) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Could not access file path'), backgroundColor: Colors.red),
          );
        }
        return;
      }

      if (mounted) {
        await showDialog(
          context: context,
          barrierDismissible: false,
          builder: (context) => VideoEditorDialog(
            videoPath: filePath,
            fileName: fileName,
            onConfirm: (startTime, endTime, cropRect, brightness, contrast, hue) {
              _showUploadDialog(filePath, fileName, startTime, endTime, cropRect,
                  brightness: brightness, contrast: contrast, hue: hue);
            },
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  Future<void> _downloadYouTubeVideo() async {
    String youtubeUrl = '';
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: const Text('Download from YouTube'),
          content: TextField(
            onChanged: (v) => setState(() => youtubeUrl = v.trim()),
            decoration: const InputDecoration(
              labelText: 'YouTube URL',
              hintText: 'https://www.youtube.com/watch?v=...',
              border: OutlineInputBorder(),
            ),
            maxLines: 2,
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
            ElevatedButton(
              onPressed: youtubeUrl.isNotEmpty ? () => Navigator.pop(context, true) : null,
              child: const Text('Download'),
            ),
          ],
        ),
      ),
    );
    if (confirmed != true || youtubeUrl.isEmpty || !mounted) return;

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => const AlertDialog(
        title: Text('Downloading Video'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [CircularProgressIndicator(), SizedBox(height: 16), Text('This may take a few minutes...')],
        ),
      ),
    );

    try {
      final fppIp = ref.read(fppIpProvider);
      final apiService = ApiService(host: fppIp);
      final result = await apiService.downloadYouTubeVideo(youtubeUrl);
      final fileName = result['filename'];
      if (!mounted) return;
      Navigator.of(context).pop();

      double downloadProgress = 0.0;
      String downloadStatus = 'Starting download...';
      late StateSetter downloadStateSetter;

      if (mounted) {
        showDialog(
          context: context,
          barrierDismissible: false,
          builder: (context) => StatefulBuilder(
            builder: (context, setState) {
              downloadStateSetter = setState;
              return AlertDialog(
                title: const Text('Downloading to Device'),
                content: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const SizedBox(height: 8),
                    LinearProgressIndicator(value: downloadProgress),
                    const SizedBox(height: 16),
                    Text('${(downloadProgress * 100).toStringAsFixed(1)}%',
                        style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                    const SizedBox(height: 8),
                    Text(downloadStatus, style: const TextStyle(fontSize: 12), textAlign: TextAlign.center),
                  ],
                ),
              );
            },
          ),
        );
      }

      try {
        final localFilePath = await apiService.downloadVideoLocally(
          fileName,
          onProgress: (received, total) {
            if (total > 0 && mounted) {
              downloadProgress = received / total;
              final receivedMB = (received / 1024 / 1024).toStringAsFixed(1);
              final totalMB = (total / 1024 / 1024).toStringAsFixed(1);
              downloadStatus = 'Downloading: $receivedMB MB / $totalMB MB';
              try { downloadStateSetter(() {}); } catch (_) {}
            }
          },
        );
        if (!mounted) return;
        Navigator.of(context).pop();
        if (mounted) {
          await showDialog(
            context: context,
            barrierDismissible: false,
            builder: (context) => VideoEditorDialog(
              videoPath: localFilePath,
              fileName: fileName,
              onConfirm: (startTime, endTime, cropRect, brightness, contrast, hue) {
                _showUploadDialog(localFilePath, fileName, startTime, endTime, cropRect,
                    brightness: brightness, contrast: contrast, hue: hue);
              },
            ),
          );
        }
      } catch (e) {
        if (!mounted) return;
        Navigator.of(context).pop();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Download failed: $e'), backgroundColor: Colors.red),
        );
      }
    } catch (e) {
      if (!mounted) return;
      Navigator.of(context).pop();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('YouTube download failed: $e'), backgroundColor: Colors.red),
      );
    }
  }

  void _showUploadDialog(
    String filePath, String fileName, double startTime, double endTime, Rect? cropRect,
    {double brightness = 0.0, double contrast = 1.0, double hue = 0.0}
  ) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => _UploadDialogContent(
        filePath: filePath,
        fileName: fileName,
        startTime: startTime,
        endTime: endTime,
        cropRect: cropRect,
        brightness: brightness,
        contrast: contrast,
        hue: hue,
        fppIp: ref.read(fppIpProvider),
        onUploadStarted: (f) => setState(() {
          _uploadingFiles.add(f);
          _uploadProgress[f] = 0.0;
        }),
        onUploadProgress: (f, p) => setState(() => _uploadProgress[f] = p),
        onRenderQueued: (orig, output) => setState(() {
          _uploadingFiles.remove(orig);
          _uploadProgress.remove(orig);
          _renderingFiles.add(output);
          if (_renderCheckTimer == null || !(_renderCheckTimer?.isActive ?? false)) {
            _startRenderCheckTimer();
          }
        }),
        onUploadFailed: (f) => setState(() {
          _uploadingFiles.remove(f);
          _uploadProgress.remove(f);
          _renderingFiles.remove(f);
        }),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Folder helpers
  // ---------------------------------------------------------------------------

  Set<String> get _scenesInFolders {
    final s = <String>{};
    for (final folder in _folders) {
      for (final entry in List<Map<String, dynamic>>.from(folder['entries'] ?? [])) {
        final video = entry['video'] as String?;
        if (video != null) s.add(video);
      }
    }
    return s;
  }

  List<String> get _ungroupedScenes => _scenes.where((s) => !_scenesInFolders.contains(s)).toList();

  Map<String, dynamic>? _getFolderByName(String name) {
    try {
      return _folders.firstWhere((f) => f['name'] == name);
    } catch (_) {
      return null;
    }
  }

  Future<void> _createFolder() async {
    String folderName = '';
    String selectedColor = '#42A5F5';

    final result = await showDialog<Map<String, String>>(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setDialogState) {
            return AlertDialog(
              title: const Text('New Folder'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  TextField(
                    autofocus: true,
                    decoration: const InputDecoration(
                      hintText: 'Folder name',
                      border: OutlineInputBorder(),
                    ),
                    onChanged: (v) => folderName = v,
                    onSubmitted: (v) {
                      if (v.trim().isNotEmpty) Navigator.pop(ctx, {'name': v.trim(), 'color': selectedColor});
                    },
                  ),
                  const SizedBox(height: 16),
                  const Text('Color', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500)),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: _folderColors.entries.map((e) {
                      final isSelected = e.key == selectedColor;
                      return GestureDetector(
                        onTap: () => setDialogState(() => selectedColor = e.key),
                        child: Container(
                          width: 32, height: 32,
                          decoration: BoxDecoration(
                            color: e.value,
                            shape: BoxShape.circle,
                            border: isSelected
                                ? Border.all(color: Colors.white, width: 3)
                                : Border.all(color: Colors.white24, width: 1),
                          ),
                          child: isSelected ? const Icon(Icons.check, size: 16, color: Colors.white) : null,
                        ),
                      );
                    }).toList(),
                  ),
                ],
              ),
              actions: [
                TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
                ElevatedButton(
                  onPressed: folderName.trim().isNotEmpty
                      ? () => Navigator.pop(ctx, {'name': folderName.trim(), 'color': selectedColor})
                      : null,
                  child: const Text('Create'),
                ),
              ],
            );
          },
        );
      },
    );

    if (result == null) return;
    try {
      final api = ApiService(host: ref.read(fppIpProvider));
      await api.createPlaylist(result['name']!, [], color: result['color']!);
      await _loadScenes();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('$e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  Future<void> _deleteFolder(String name) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Folder'),
        content: Text('Delete folder "$name"?\n\nScenes inside will become ungrouped.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      final api = ApiService(host: ref.read(fppIpProvider));
      await api.deletePlaylist(name);
      if (_currentFolder == name) _currentFolder = null;
      await _loadScenes();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('$e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  Future<void> _playFolder(String name) async {
    try {
      final api = ApiService(host: ref.read(fppIpProvider));
      await api.playPlaylist(name, loop: _isLooping, brightness: _brightness, playbackFps: _playbackFps);
      setState(() => _currentlyPlaying = 'playlist:$name');
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('$e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  Future<void> _saveFolderEntries(String name, List<Map<String, dynamic>> entries,
      {double? transitionDuration, String? color, double? playDuration, bool? shuffle}) async {
    try {
      final api = ApiService(host: ref.read(fppIpProvider));
      await api.updatePlaylist(name, entries,
          transitionDuration: transitionDuration, color: color,
          playDuration: playDuration, shuffle: shuffle);
      await _loadScenes();
      if (_currentlyPlaying == 'playlist:$name') await _playFolder(name);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('$e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  Future<void> _addScenesToFolder(String folderName) async {
    final folder = _getFolderByName(folderName);
    if (folder == null) return;

    final fppIp = ref.read(fppIpProvider);
    final apiService = ApiService(host: fppIp);

    final selected = await showDialog<List<String>>(
      context: context,
      builder: (ctx) => _ScenePickerDialog(
        scenes: _scenes, // All scenes available (duplicates allowed)
        displayName: _displayName,
        thumbnailUrl: apiService.getThumbnailUrl,
      ),
    );
    if (selected == null || selected.isEmpty) return;

    final entries = List<Map<String, dynamic>>.from(folder['entries'] ?? []);
    for (final s in selected) {
      entries.add({'video': s, 'transition': 'fade'});
    }
    await _saveFolderEntries(folderName, entries);
  }

  void _removeSceneFromFolder(String folderName, int index) {
    final folder = _getFolderByName(folderName);
    if (folder == null) return;
    final entries = List<Map<String, dynamic>>.from(folder['entries'] ?? []);
    if (index < 0 || index >= entries.length) return;
    entries.removeAt(index);
    _saveFolderEntries(folderName, entries);
  }

  void _setSceneTransition(String folderName, int index, String transition) {
    final folder = _getFolderByName(folderName);
    if (folder == null) return;
    final entries = List<Map<String, dynamic>>.from(folder['entries'] ?? []);
    if (index < 0 || index >= entries.length) return;
    entries[index] = Map<String, dynamic>.from(entries[index])..['transition'] = transition;
    _saveFolderEntries(folderName, entries);
  }

  void _setEntryDuration(String folderName, int index, double? duration) {
    final folder = _getFolderByName(folderName);
    if (folder == null) return;
    final entries = List<Map<String, dynamic>>.from(folder['entries'] ?? []);
    if (index < 0 || index >= entries.length) return;
    final entry = Map<String, dynamic>.from(entries[index]);
    if (duration == null || duration <= 0) {
      entry.remove('duration');
    } else {
      entry['duration'] = duration;
      entry.remove('loop_count'); // duration and loop_count are mutually exclusive
    }
    entries[index] = entry;
    _saveFolderEntries(folderName, entries);
  }

  void _setEntryLoopCount(String folderName, int index, int loopCount) {
    final folder = _getFolderByName(folderName);
    if (folder == null) return;
    final entries = List<Map<String, dynamic>>.from(folder['entries'] ?? []);
    if (index < 0 || index >= entries.length) return;
    final entry = Map<String, dynamic>.from(entries[index]);
    if (loopCount <= 0) {
      entry.remove('loop_count');
    } else {
      entry['loop_count'] = loopCount;
      entry.remove('duration'); // mutually exclusive
    }
    entries[index] = entry;
    _saveFolderEntries(folderName, entries);
  }

  void _addSceneToFolderByDrag(String folderName, String sceneName) {
    final folder = _getFolderByName(folderName);
    if (folder == null) return;
    final entries = List<Map<String, dynamic>>.from(folder['entries'] ?? []);
    // Don't add duplicate in same folder
    if (entries.any((e) => e['video'] == sceneName)) return;
    entries.add({'video': sceneName, 'transition': 'fade'});
    _saveFolderEntries(folderName, entries);
  }

  Future<void> _changeFolderColor(String folderName) async {
    final folder = _getFolderByName(folderName);
    if (folder == null) return;
    final currentColor = folder['color'] as String? ?? '#42A5F5';

    String selectedColor = currentColor;
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: const Text('Folder Color'),
          content: Wrap(
            spacing: 10,
            runSpacing: 10,
            children: _folderColors.entries.map((e) {
              final isSelected = e.key == selectedColor;
              return GestureDetector(
                onTap: () => setDialogState(() => selectedColor = e.key),
                child: Container(
                  width: 40, height: 40,
                  decoration: BoxDecoration(
                    color: e.value,
                    shape: BoxShape.circle,
                    border: isSelected
                        ? Border.all(color: Colors.white, width: 3)
                        : Border.all(color: Colors.white24, width: 1),
                  ),
                  child: isSelected ? const Icon(Icons.check, size: 20, color: Colors.white) : null,
                ),
              );
            }).toList(),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
            ElevatedButton(onPressed: () => Navigator.pop(ctx, selectedColor), child: const Text('Save')),
          ],
        ),
      ),
    );
    if (result == null || result == currentColor) return;
    final entries = List<Map<String, dynamic>>.from(folder['entries'] ?? []);
    final td = (folder['transition_duration'] as num?)?.toDouble();
    final pd = (folder['play_duration'] as num?)?.toDouble();
    final sh = folder['shuffle'] as bool?;
    await _saveFolderEntries(folderName, entries, color: result,
        transitionDuration: td, playDuration: pd, shuffle: sh);
  }

  // ---------------------------------------------------------------------------
  // BUILD
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final fppIp = ref.watch(fppIpProvider);

    // Inside a folder
    if (_currentFolder != null) {
      return _buildFolderView(fppIp);
    }

    // Root view
    return _buildRootView(fppIp);
  }

  Widget _buildRootView(String fppIp) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Scenes'),
        centerTitle: true,
        actions: [
          IconButton(
            icon: const Icon(Icons.calendar_today),
            tooltip: 'Schedules',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const SchedulesPage()),
            ),
          ),
          IconButton(icon: const Icon(Icons.create_new_folder_outlined), tooltip: 'New folder', onPressed: _createFolder),
          IconButton(icon: const Icon(Icons.add), tooltip: 'Upload video', onPressed: _uploadAndRenderVideo),
          IconButton(icon: const Icon(Icons.refresh), onPressed: _loadScenes),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                return SingleChildScrollView(
                  controller: _scrollController,
                  padding: const EdgeInsets.only(bottom: 16),
                  child: ConstrainedBox(
                    constraints: BoxConstraints(minHeight: constraints.maxHeight),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        // Controls bar
                        _buildControlsBar(),
                        // Grid
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                          child: _isLoading
                              ? const Center(child: Padding(padding: EdgeInsets.all(48), child: CircularProgressIndicator()))
                              : _error != null
                                  ? _buildErrorView()
                                  : _buildRootGrid(fppIp),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
          _buildNowPlayingBar(),
        ],
      ),
    );
  }

  Widget _buildFolderView(String fppIp) {
    final folder = _getFolderByName(_currentFolder!);
    final entries = List<Map<String, dynamic>>.from(folder?['entries'] ?? []);
    final folderColor = _colorFromHex(folder?['color'] as String? ?? '#42A5F5');
    final isFolderPlaying = _currentlyPlaying == 'playlist:${_currentFolder}';
    final isShuffle = folder?['shuffle'] as bool? ?? false;

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => setState(() => _currentFolder = null),
        ),
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.folder, color: folderColor, size: 22),
            const SizedBox(width: 8),
            Flexible(child: Text(_currentFolder!, overflow: TextOverflow.ellipsis)),
          ],
        ),
        centerTitle: true,
        actions: [
          IconButton(
            icon: Icon(isFolderPlaying ? Icons.stop : Icons.play_arrow,
                color: isFolderPlaying ? Colors.red[300] : Colors.green[300]),
            tooltip: isFolderPlaying ? 'Stop' : 'Play folder',
            onPressed: () => isFolderPlaying ? _stopPlayback() : _playFolder(_currentFolder!),
          ),
          IconButton(
            icon: const Icon(Icons.add),
            tooltip: 'Add scenes',
            onPressed: () => _addScenesToFolder(_currentFolder!),
          ),
          IconButton(
            icon: Icon(
              Icons.shuffle,
              color: isShuffle ? Colors.cyanAccent : Colors.grey[500],
            ),
            tooltip: isShuffle ? 'Shuffle: On' : 'Shuffle: Off',
            onPressed: () {
              _saveFolderEntries(
                _currentFolder!, entries,
                shuffle: !isShuffle,
              );
            },
          ),
          PopupMenuButton<String>(
            onSelected: (v) {
              if (v == 'color') _changeFolderColor(_currentFolder!);
              if (v == 'delete') _deleteFolder(_currentFolder!);
            },
            itemBuilder: (_) => [
              const PopupMenuItem(value: 'color', child: Text('Change color')),
              const PopupMenuItem(value: 'delete', child: Text('Delete folder', style: TextStyle(color: Colors.red))),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: Column(
              children: [
                _buildControlsBar(),
                Expanded(
                  child: entries.isEmpty
                      ? Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.folder_open, size: 64, color: Colors.grey[700]),
                              const SizedBox(height: 12),
                              Text('No scenes in this folder', style: TextStyle(color: Colors.grey[500])),
                              const SizedBox(height: 16),
                              ElevatedButton.icon(
                                onPressed: () => _addScenesToFolder(_currentFolder!),
                                icon: const Icon(Icons.add, size: 18),
                                label: const Text('Add scenes'),
                              ),
                            ],
                          ),
                        )
                      : GridView.builder(
                          padding: const EdgeInsets.all(8),
                          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                            crossAxisCount: 2,
                            crossAxisSpacing: 10,
                            mainAxisSpacing: 10,
                            childAspectRatio: 1.0,
                          ),
                          itemCount: entries.length,
                          itemBuilder: (context, index) {
                            final entry = entries[index];
                            final video = entry['video'] as String? ?? '';
                            final transition = entry['transition'] as String? ?? 'fade';
                            return DragTarget<int>(
                              onWillAcceptWithDetails: (details) => details.data != index,
                              onAcceptWithDetails: (details) {
                                final fromIndex = details.data;
                                final newEntries = List<Map<String, dynamic>>.from(entries);
                                final moved = newEntries.removeAt(fromIndex);
                                newEntries.insert(index, moved);
                                _saveFolderEntries(
                                  _currentFolder!, newEntries,
                                  shuffle: isShuffle,
                                );
                              },
                              builder: (context, candidateData, rejectedData) {
                                final isHovering = candidateData.isNotEmpty;
                                return LongPressDraggable<int>(
                                  data: index,
                                  delay: const Duration(milliseconds: 200),
                                  feedback: Material(
                                    color: Colors.transparent,
                                    child: SizedBox(
                                      width: 130, height: 130,
                                      child: Opacity(
                                        opacity: 0.85,
                                        child: _buildSceneCardInFolder(video, index, transition, fppIp),
                                      ),
                                    ),
                                  ),
                                  childWhenDragging: Opacity(
                                    opacity: 0.3,
                                    child: _buildSceneCardInFolder(video, index, transition, fppIp),
                                  ),
                                  child: AnimatedContainer(
                                    duration: const Duration(milliseconds: 150),
                                    decoration: isHovering
                                        ? BoxDecoration(
                                            borderRadius: BorderRadius.circular(12),
                                            border: Border.all(color: Colors.cyanAccent, width: 2),
                                          )
                                        : null,
                                    child: _buildSceneCardInFolder(video, index, transition, fppIp),
                                  ),
                                );
                              },
                            );
                          },
                        ),
                ),
              ],
            ),
          ),
          _buildNowPlayingBar(),
        ],
      ),
    );
  }

  Widget _buildNowPlayingBar() {
    if (_currentlyPlaying == null) return const SizedBox.shrink();

    final isPlaylist = _currentlyPlaying!.startsWith('playlist:');
    final displayTitle = isPlaylist
        ? '📁 ${_currentlyPlaying!.substring('playlist:'.length)}'
        : _displayName(_currentlyPlaying!);

    return SafeArea(
      top: false,
      child: Container(
        decoration: BoxDecoration(
          color: Colors.green[900]!.withValues(alpha: 0.95),
          border: Border(top: BorderSide(color: Colors.green[700]!, width: 1)),
          boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.4), blurRadius: 8, offset: const Offset(0, -2))],
        ),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(
          children: [
            // Animated play icon
            const Icon(Icons.play_circle_fill, color: Colors.greenAccent, size: 28),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Now Playing', style: TextStyle(fontSize: 10, color: Colors.green, fontWeight: FontWeight.w600, letterSpacing: 0.5)),
                  const SizedBox(height: 1),
                  Text(
                    displayTitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 14),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            TextButton.icon(
              onPressed: _stopPlayback,
              icon: const Icon(Icons.stop_circle_outlined, size: 20),
              label: const Text('Stop'),
              style: TextButton.styleFrom(
                foregroundColor: Colors.red[300],
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                minimumSize: Size.zero,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildControlsBar() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.grey[900],
        border: Border(bottom: BorderSide(color: Colors.grey[800]!, width: 0.5)),
      ),
      child: Row(
        children: [
          // Loop toggle
          InkWell(
            borderRadius: BorderRadius.circular(6),
            onTap: () => setState(() => _isLooping = !_isLooping),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    _isLooping ? Icons.repeat_on : Icons.repeat,
                    size: 18,
                    color: _isLooping ? Colors.cyanAccent : Colors.grey[500],
                  ),
                  const SizedBox(width: 4),
                  Text('Loop', style: TextStyle(fontSize: 12, color: _isLooping ? Colors.cyanAccent : Colors.grey[500])),
                ],
              ),
            ),
          ),
          const SizedBox(width: 12),
          // Brightness
          Icon(Icons.brightness_6, size: 16, color: Colors.grey[500]),
          Expanded(
            child: SliderTheme(
              data: SliderThemeData(
                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
                trackHeight: 3,
                overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
                activeTrackColor: Colors.cyanAccent.withValues(alpha: 0.7),
                thumbColor: Colors.cyanAccent,
              ),
              child: Slider(
                value: _brightness.clamp(0.1, 2.0),
                min: 0.1, max: 2.0, divisions: 19,
                label: '${_brightness.toStringAsFixed(1)}x',
                onChanged: (value) {
                  setState(() => _brightness = value);
                  _updateBrightness(value);
                },
              ),
            ),
          ),
          Text('${_brightness.toStringAsFixed(1)}x',
              style: TextStyle(fontSize: 12, color: Colors.grey[400])),
        ],
      ),
    );
  }

  Widget _buildErrorView() {
    return Column(
      children: [
        const SizedBox(height: 48),
        const Icon(Icons.error_outline, size: 48, color: Colors.red),
        const SizedBox(height: 12),
        Text('Error: $_error', textAlign: TextAlign.center),
        const SizedBox(height: 12),
        ElevatedButton(onPressed: _loadScenes, child: const Text('Retry')),
      ],
    );
  }

  Widget _buildRootGrid(String fppIp) {
    final uploadingList = _uploadingFiles.toList()..sort();
    final renderingList = _renderingFiles.toList()..sort();
    final ungrouped = _ungroupedScenes;
    final hasContent = _folders.isNotEmpty || uploadingList.isNotEmpty ||
        renderingList.isNotEmpty || ungrouped.isNotEmpty;

    if (!hasContent) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(48),
          child: Text('No scenes found', style: TextStyle(color: Colors.grey)),
        ),
      );
    }

    // Build a flat list: folders -> uploading -> rendering -> ungrouped scenes
    final items = <_GridItem>[
      ..._folders.map((f) => _GridItem(type: _GridItemType.folder, data: f)),
      ...uploadingList.map((f) => _GridItem(type: _GridItemType.uploading, name: f)),
      ...renderingList.map((f) => _GridItem(type: _GridItemType.rendering, name: f)),
      ...ungrouped.map((s) => _GridItem(type: _GridItemType.scene, name: s)),
    ];

    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        crossAxisSpacing: 10,
        mainAxisSpacing: 10,
        childAspectRatio: 1.0,
      ),
      padding: const EdgeInsets.symmetric(horizontal: 4),
      itemCount: items.length,
      itemBuilder: (context, index) {
        final item = items[index];
        switch (item.type) {
          case _GridItemType.folder:
            return _buildFolderCard(item.data as Map<String, dynamic>);
          case _GridItemType.uploading:
            return _buildUploadingCard(item.name!, _uploadProgress[item.name] ?? 0.0);
          case _GridItemType.rendering:
            return _buildRenderingCard(item.name!);
          case _GridItemType.scene:
            final key = _itemKeys.putIfAbsent(item.name!, () => GlobalKey());
            final isHighlighted = _activeHighlight == item.name;
            return KeyedSubtree(
              key: key,
              child: LongPressDraggable<String>(
                data: item.name!,
                delay: const Duration(milliseconds: 200),
                feedback: Material(
                  color: Colors.transparent,
                  child: SizedBox(
                    width: 120, height: 120,
                    child: Opacity(opacity: 0.8, child: _buildSceneCard(item.name!, isHighlighted: false)),
                  ),
                ),
                childWhenDragging: Opacity(opacity: 0.3, child: _buildSceneCard(item.name!, isHighlighted: false)),
                child: _buildSceneCard(item.name!, isHighlighted: isHighlighted),
              ),
            );
        }
      },
    );
  }

  // ---------------------------------------------------------------------------
  // Card widgets
  // ---------------------------------------------------------------------------

  Widget _buildFolderCard(Map<String, dynamic> folder) {
    final name = folder['name'] as String;
    final entries = List<Map<String, dynamic>>.from(folder['entries'] ?? []);
    final colorHex = folder['color'] as String? ?? '#42A5F5';
    final color = _colorFromHex(colorHex);
    final isPlaying = _currentlyPlaying == 'playlist:$name';

    return DragTarget<String>(
      onWillAcceptWithDetails: (_) => true,
      onAcceptWithDetails: (details) => _addSceneToFolderByDrag(name, details.data),
      builder: (context, candidateData, rejectedData) {
        final isHovering = candidateData.isNotEmpty;
        return GestureDetector(
          onTap: () => setState(() => _currentFolder = name),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: isHovering ? color : color.withValues(alpha: 0.4),
                width: isHovering ? 3 : 1.5,
              ),
              color: isHovering
                  ? color.withValues(alpha: 0.2)
                  : Colors.grey[850],
            ),
            child: Stack(
              children: [
                // Content
                Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Expanded(
                      child: Center(
                        child: Icon(Icons.folder_rounded,
                            size: 64, color: color),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(8, 0, 8, 10),
                      child: Column(
                        children: [
                          Text(
                            name,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                              fontWeight: FontWeight.w600,
                              fontSize: 14,
                              color: Colors.white,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            '${entries.length} scene${entries.length == 1 ? '' : 's'}',
                            style: TextStyle(fontSize: 12, color: Colors.grey[500]),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                // Playing indicator
                if (isPlaying)
                  Positioned(
                    top: 8, right: 8,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: Colors.green,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: const Text('\u25B6', style: TextStyle(fontSize: 10, color: Colors.white)),
                    ),
                  ),
                // Drag hover hint
                if (isHovering)
                  Positioned.fill(
                    child: Container(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(12),
                        color: color.withValues(alpha: 0.15),
                      ),
                      child: Center(
                        child: Icon(Icons.add_circle_outline, size: 36, color: color),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildSceneCard(String sceneName, {bool isHighlighted = false}) {
    final isPlaying = _currentlyPlaying == sceneName;
    final fppIp = ref.read(fppIpProvider);
    final apiService = ApiService(host: fppIp);
    final thumbnailUrl = apiService.getThumbnailUrl(sceneName);

    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        border: isHighlighted ? Border.all(color: Colors.blueAccent, width: 3) : null,
        boxShadow: isHighlighted
            ? [BoxShadow(color: Colors.blueAccent.withValues(alpha: 0.5), blurRadius: 12, spreadRadius: 2)]
            : null,
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: Stack(
          fit: StackFit.expand,
          children: [
            // Thumbnail
            Container(
              color: Colors.black,
              child: Image.network(
                thumbnailUrl,
                fit: BoxFit.cover,
                gaplessPlayback: true,
                errorBuilder: (_, __, ___) => Container(
                  color: Colors.grey[800],
                  child: Icon(Icons.movie, size: 48, color: Colors.grey[600]),
                ),
              ),
            ),
            // Gradient overlay
            Container(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.black.withValues(alpha: 0.5),
                    Colors.transparent,
                    Colors.black.withValues(alpha: 0.75),
                  ],
                  stops: const [0.0, 0.4, 1.0],
                ),
              ),
            ),
            // Content
            Padding(
              padding: const EdgeInsets.all(8),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  // Title
                  Padding(
                    padding: const EdgeInsets.only(top: 4, left: 4, right: 4),
                    child: Text(
                      _displayName(sceneName),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                        fontSize: 12,
                        shadows: [Shadow(offset: Offset(1, 1), blurRadius: 3, color: Colors.black)],
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ),
                  // Bottom controls row
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      // Play/Stop
                      _CircleButton(
                        icon: isPlaying ? Icons.stop : Icons.play_arrow,
                        color: isPlaying ? Colors.red : Colors.green,
                        onTap: () => isPlaying ? _stopPlayback() : _playScene(sceneName),
                      ),
                      // Edit menu
                      PopupMenuButton<String>(
                        onSelected: (v) {
                          if (v == 'color_adjust') _recolorVideo(sceneName);
                          if (v == 'trim') _trimVideo(sceneName);
                          if (v == 'rename') _renameVideo(sceneName);
                          if (v == 'delete') _deleteVideo(sceneName);
                        },
                        itemBuilder: (_) => [
                          const PopupMenuItem(value: 'color_adjust', child: Row(children: [Icon(Icons.tune, size: 18, color: Colors.cyanAccent), SizedBox(width: 8), Text('Color Adjust')])),
                          const PopupMenuItem(value: 'trim', child: Row(children: [Icon(Icons.cut, size: 18), SizedBox(width: 8), Text('Trim')])),
                          const PopupMenuItem(value: 'rename', child: Row(children: [Icon(Icons.edit, size: 18), SizedBox(width: 8), Text('Rename')])),
                          PopupMenuItem(value: 'delete', child: Row(children: [Icon(Icons.delete, size: 18, color: Colors.red[300]), const SizedBox(width: 8), Text('Delete', style: TextStyle(color: Colors.red[300]))])),
                        ],
                        color: Colors.grey[850],
                        padding: EdgeInsets.zero,
                        child: Container(
                          padding: const EdgeInsets.all(7),
                          decoration: BoxDecoration(
                            color: Colors.black.withValues(alpha: 0.55),
                            shape: BoxShape.circle,
                            border: Border.all(color: Colors.white24, width: 0.5),
                          ),
                          child: const Icon(Icons.more_vert, color: Colors.white70, size: 18),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            // Playing indicator
            if (isPlaying)
              Positioned(
                top: 6, right: 6,
                child: Container(
                  width: 10, height: 10,
                  decoration: BoxDecoration(
                    color: Colors.green,
                    shape: BoxShape.circle,
                    boxShadow: [BoxShadow(color: Colors.green.withValues(alpha: 0.5), blurRadius: 6)],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// Scene card inside a folder -- includes transition badge and per-entry settings
  Widget _buildSceneCardInFolder(String sceneName, int index, String transition, String fppIp) {
    final isPlaying = _currentlyPlaying == sceneName;
    final apiService = ApiService(host: fppIp);
    final thumbnailUrl = apiService.getThumbnailUrl(sceneName);

    // Read per-entry settings from folder
    final folder = _getFolderByName(_currentFolder ?? '');
    final entries = List<Map<String, dynamic>>.from(folder?['entries'] ?? []);
    final entry = index < entries.length ? entries[index] : <String, dynamic>{};
    final entryDuration = (entry['duration'] as num?)?.toDouble() ?? 0.0;
    final entryLoopCount = (entry['loop_count'] as num?)?.toInt() ?? 0;

    String durationBadge;
    if (entryLoopCount > 0) {
      durationBadge = '×$entryLoopCount';
    } else if (entryDuration > 0) {
      durationBadge = '${entryDuration.toStringAsFixed(0)}s';
    } else {
      durationBadge = '∞';
    }

    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: Stack(
        fit: StackFit.expand,
        children: [
          // Thumbnail
          Container(
            color: Colors.black,
            child: Image.network(
              thumbnailUrl,
              fit: BoxFit.cover,
              gaplessPlayback: true,
              errorBuilder: (_, __, ___) => Container(
                color: Colors.grey[800],
                child: Icon(Icons.movie, size: 48, color: Colors.grey[600]),
              ),
            ),
          ),
          // Gradient overlay
          Container(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Colors.black.withValues(alpha: 0.5),
                  Colors.transparent,
                  Colors.black.withValues(alpha: 0.75),
                ],
                stops: const [0.0, 0.4, 1.0],
              ),
            ),
          ),
          // Content
          Padding(
            padding: const EdgeInsets.all(8),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                // Title row (leave space for badges)
                Padding(
                  padding: const EdgeInsets.only(top: 20, left: 36, right: 28),
                  child: Text(
                    _displayName(sceneName),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                      fontSize: 12,
                      shadows: [Shadow(offset: Offset(1, 1), blurRadius: 3, color: Colors.black)],
                    ),
                    textAlign: TextAlign.center,
                  ),
                ),
                // Bottom controls row
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    // Play/Stop
                    _CircleButton(
                      icon: isPlaying ? Icons.stop : Icons.play_arrow,
                      color: isPlaying ? Colors.red : Colors.green,
                      onTap: () => isPlaying ? _stopPlayback() : _playScene(sceneName),
                    ),
                    // Settings button (playback: loop/transition)
                    GestureDetector(
                      onTap: () => _showEntrySettingsSheet(index, transition, entryDuration, entryLoopCount),
                      child: Container(
                        padding: const EdgeInsets.all(7),
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.55),
                          shape: BoxShape.circle,
                          border: Border.all(color: Colors.white24, width: 0.5),
                        ),
                        child: const Icon(Icons.tune, color: Colors.white70, size: 18),
                      ),
                    ),
                    // Edit menu (color adjust, trim, rename)
                    PopupMenuButton<String>(
                      onSelected: (v) {
                        if (v == 'color_adjust') _recolorVideo(sceneName);
                        if (v == 'trim') _trimVideo(sceneName);
                        if (v == 'rename') _renameVideo(sceneName);
                      },
                      itemBuilder: (_) => [
                        const PopupMenuItem(value: 'color_adjust', child: Row(children: [Icon(Icons.tune, size: 18, color: Colors.cyanAccent), SizedBox(width: 8), Text('Color Adjust')])),
                        const PopupMenuItem(value: 'trim', child: Row(children: [Icon(Icons.cut, size: 18), SizedBox(width: 8), Text('Trim')])),
                        const PopupMenuItem(value: 'rename', child: Row(children: [Icon(Icons.edit, size: 18), SizedBox(width: 8), Text('Rename')])),
                      ],
                      color: Colors.grey[850],
                      padding: EdgeInsets.zero,
                      child: Container(
                        padding: const EdgeInsets.all(7),
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.55),
                          shape: BoxShape.circle,
                          border: Border.all(color: Colors.white24, width: 0.5),
                        ),
                        child: const Icon(Icons.more_vert, color: Colors.white70, size: 18),
                      ),
                    ),
                    // Remove
                    _CircleButton(
                      icon: Icons.close,
                      color: Colors.grey[800]!,
                      onTap: () => _removeSceneFromFolder(_currentFolder!, index),
                    ),
                  ],
                ),
              ],
            ),
          ),
          // Duration badge (top-right area, next to order badge)
          Positioned(
            top: 6, right: 28,
            child: GestureDetector(
              onTap: () => _showEntrySettingsSheet(index, transition, entryDuration, entryLoopCount),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.7),
                  borderRadius: BorderRadius.circular(5),
                  border: Border.all(color: Colors.orangeAccent.withValues(alpha: 0.4), width: 0.5),
                ),
                child: Text(durationBadge, style: TextStyle(fontSize: 9, color: Colors.orange[300])),
              ),
            ),
          ),
          // Order badge (top-right)
          Positioned(
            top: 6, right: 6,
            child: Container(
              width: 20, height: 20,
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.7),
                shape: BoxShape.circle,
              ),
              child: Center(
                child: Text('${index + 1}', style: const TextStyle(fontSize: 9, color: Colors.white70)),
              ),
            ),
          ),
          // Playing indicator
          if (isPlaying)
            Positioned(
              bottom: 6, right: 6,
              child: Container(
                width: 10, height: 10,
                decoration: BoxDecoration(
                  color: Colors.green,
                  shape: BoxShape.circle,
                  boxShadow: [BoxShadow(color: Colors.green.withValues(alpha: 0.5), blurRadius: 6)],
                ),
              ),
            ),
        ],
      ),
    );
  }

  void _showEntrySettingsSheet(int index, String currentTransition, double currentDuration, int currentLoopCount) {
    // Determine current mode: 'folder' = use folder default, 'time' = fixed seconds, 'loops' = repeat N times
    String mode = currentLoopCount > 0 ? 'loops' : (currentDuration > 0 ? 'time' : 'loops');
    double duration = currentDuration > 0 ? currentDuration : 5.0;
    int loopCount = currentLoopCount > 0 ? currentLoopCount : 1;
    String selectedTransition = currentTransition;

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.grey[900],
      isScrollControlled: true,
      useSafeArea: true,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheetState) {
          final bottomInset = MediaQuery.of(ctx).viewInsets.bottom;
          return Padding(
            padding: EdgeInsets.fromLTRB(20, 12, 20, 24 + bottomInset),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Handle
                Center(
                  child: Container(
                    width: 36, height: 4,
                    decoration: BoxDecoration(color: Colors.grey[700], borderRadius: BorderRadius.circular(2)),
                  ),
                ),
                const SizedBox(height: 14),
                const Text('Clip Settings', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.white)),
                const SizedBox(height: 16),

                // --- Playback Mode ---
                Text('Playback Duration', style: TextStyle(fontSize: 12, color: Colors.grey[400], fontWeight: FontWeight.w600, letterSpacing: 0.5)),
                const SizedBox(height: 8),
                SegmentedButton<String>(
                  segments: const [
                    ButtonSegment(value: 'time', label: Text('Fixed time'), icon: Icon(Icons.timer_outlined, size: 14)),
                    ButtonSegment(value: 'loops', label: Text('Loop count'), icon: Icon(Icons.repeat, size: 14)),
                  ],
                  selected: {mode},
                  onSelectionChanged: (s) => setSheetState(() => mode = s.first),
                  style: ButtonStyle(
                    textStyle: WidgetStateProperty.all(const TextStyle(fontSize: 11)),
                    visualDensity: VisualDensity.compact,
                  ),
                ),
                const SizedBox(height: 12),

                if (mode == 'time') ...[
                  Row(
                    children: [
                      const Icon(Icons.timer, size: 16, color: Colors.orange),
                      const SizedBox(width: 8),
                      Text('Play for ${duration.toStringAsFixed(0)}s',
                          style: const TextStyle(fontSize: 13, color: Colors.white)),
                    ],
                  ),
                  Slider(
                    value: duration,
                    min: 1.0, max: 60.0, divisions: 59,
                    label: '${duration.toStringAsFixed(0)}s',
                    activeColor: Colors.orange,
                    onChanged: (v) => setSheetState(() => duration = v),
                  ),
                ] else if (mode == 'loops') ...[
                  Row(
                    children: [
                      const Icon(Icons.repeat, size: 16, color: Colors.orange),
                      const SizedBox(width: 8),
                      Text('Repeat $loopCount time${loopCount == 1 ? '' : 's'}',
                          style: const TextStyle(fontSize: 13, color: Colors.white)),
                    ],
                  ),
                  Slider(
                    value: loopCount.toDouble(),
                    min: 1.0, max: 20.0, divisions: 19,
                    label: '×$loopCount',
                    activeColor: Colors.orange,
                    onChanged: (v) => setSheetState(() => loopCount = v.round()),
                  ),
                ],

                const SizedBox(height: 16),
                Divider(color: Colors.grey[800], height: 1),
                const SizedBox(height: 12),

                // --- Transition ---
                Text('Transition In', style: TextStyle(fontSize: 12, color: Colors.grey[400], fontWeight: FontWeight.w600, letterSpacing: 0.5)),
                const SizedBox(height: 8),
                SizedBox(
                  height: 36,
                  child: ListView(
                    scrollDirection: Axis.horizontal,
                    children: _transitions.map((t) {
                      final label = t == 'fisheye_swirl' ? 'swirl' : t;
                      final isSelected = t == selectedTransition;
                      return Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: GestureDetector(
                          onTap: () => setSheetState(() => selectedTransition = t),
                          child: AnimatedContainer(
                            duration: const Duration(milliseconds: 120),
                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                            decoration: BoxDecoration(
                              color: isSelected ? Colors.cyanAccent.withValues(alpha: 0.2) : Colors.grey[800],
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(
                                color: isSelected ? Colors.cyanAccent : Colors.grey[700]!,
                                width: isSelected ? 1.5 : 1,
                              ),
                            ),
                            child: Text(label, style: TextStyle(
                              fontSize: 12,
                              color: isSelected ? Colors.cyanAccent : Colors.white70,
                              fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                            )),
                          ),
                        ),
                      );
                    }).toList(),
                  ),
                ),
                const SizedBox(height: 20),

                // --- Save button ---
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    onPressed: () {
                      Navigator.pop(ctx);
                      // Save transition
                      if (selectedTransition != currentTransition) {
                        _setSceneTransition(_currentFolder!, index, selectedTransition);
                      }
                      // Save duration/loop
                      if (mode == 'loops') {
                        _setEntryLoopCount(_currentFolder!, index, loopCount);
                      } else {
                        _setEntryDuration(_currentFolder!, index, duration);
                      }
                    },
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.cyanAccent,
                      foregroundColor: Colors.black,
                      padding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                    child: const Text('Save', style: TextStyle(fontWeight: FontWeight.bold)),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _buildUploadingCard(String fileName, double progress) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: Container(
        color: Colors.orange[900],
        child: Stack(
          fit: StackFit.expand,
          children: [
            Container(
              color: Colors.orange[800],
              child: const Center(child: Icon(Icons.cloud_upload, size: 48, color: Colors.white30)),
            ),
            Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const CircularProgressIndicator(color: Colors.white, strokeWidth: 3),
                        const SizedBox(height: 12),
                        Text(_displayName(fileName),
                            maxLines: 2, overflow: TextOverflow.ellipsis,
                            style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                            textAlign: TextAlign.center),
                      ],
                    ),
                  ),
                  LinearProgressIndicator(value: progress, backgroundColor: Colors.white24, minHeight: 3),
                  const SizedBox(height: 4),
                  Center(child: Text('${(progress * 100).toInt()}%', style: const TextStyle(color: Colors.white, fontSize: 12))),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildRenderingCard(String fileName) {
    final progress = _renderProgress[fileName] ?? 0.0;
    final percentage = (progress * 100).toStringAsFixed(0);
    final framesRendered = _renderFramesCurrent[fileName] ?? 0;
    final totalFrames = _renderFramesTotal[fileName] ?? 0;

    String statusText;
    if (totalFrames > 0) {
      statusText = '$framesRendered / $totalFrames frames';
    } else if (progress > 0) {
      statusText = 'Rendering $percentage%...';
    } else {
      statusText = 'Starting render...';
    }

    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: Container(
        color: Colors.blueGrey[900],
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              SizedBox(
                width: 56, height: 56,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    CircularProgressIndicator(
                      value: progress > 0 ? progress : null,
                      strokeWidth: 3,
                      color: Colors.white,
                      backgroundColor: Colors.white24,
                    ),
                    Text('$percentage%', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13)),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              Text(_displayName(fileName),
                  maxLines: 2, overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                  textAlign: TextAlign.center),
              const SizedBox(height: 6),
              Text(statusText, style: const TextStyle(color: Colors.white70, fontSize: 11)),
              const SizedBox(height: 8),
              LinearProgressIndicator(
                value: progress > 0 ? progress : null,
                backgroundColor: Colors.white24,
                valueColor: const AlwaysStoppedAnimation<Color>(Colors.blue),
                minHeight: 3,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// Small circular button used in scene cards
class _CircleButton extends StatelessWidget {
  final IconData icon;
  final Color color;
  final VoidCallback onTap;

  const _CircleButton({required this.icon, required this.color, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: color,
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Icon(icon, color: Colors.white, size: 22),
        ),
      ),
    );
  }
}

// Grid item types for root view
enum _GridItemType { folder, uploading, rendering, scene }

class _GridItem {
  final _GridItemType type;
  final String? name;
  final Map<String, dynamic>? data;
  const _GridItem({required this.type, this.name, this.data});
}

// ---------------------------------------------------------------------------
// Upload dialog (unchanged)
// ---------------------------------------------------------------------------

class _UploadDialogContent extends StatefulWidget {
  final String filePath;
  final String fileName;
  final double startTime;
  final double endTime;
  final Rect? cropRect;
  final double brightness;
  final double contrast;
  final double hue;
  final String fppIp;
  final Function(String) onUploadStarted;
  final Function(String, double) onUploadProgress;
  final Function(String, String) onRenderQueued;
  final Function(String) onUploadFailed;

  const _UploadDialogContent({
    required this.filePath,
    required this.fileName,
    required this.startTime,
    required this.endTime,
    required this.cropRect,
    required this.brightness,
    required this.contrast,
    required this.hue,
    required this.fppIp,
    required this.onUploadStarted,
    required this.onUploadProgress,
    required this.onRenderQueued,
    required this.onUploadFailed,
  });

  @override
  State<_UploadDialogContent> createState() => _UploadDialogContentState();
}

class _UploadDialogContentState extends State<_UploadDialogContent> {
  late TextEditingController _nameController;
  bool _isUploading = false;
  String? _status;
  double _uploadProgress = 0;
  static const int _defaultRenderFps = 20;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: _removeExtension(widget.fileName));
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  String _removeExtension(String filename) {
    final lastDot = filename.lastIndexOf('.');
    if (lastDot != -1) return filename.substring(0, lastDot);
    return filename;
  }

  Future<void> _performUpload() async {
    setState(() {
      _isUploading = true;
      _status = 'Reading file...';
      _uploadProgress = 0.1;
    });
    widget.onUploadStarted(widget.fileName);

    try {
      final file = io.File(widget.filePath);
      final fileBytes = await file.readAsBytes();
      if (!mounted) return;

      setState(() { _uploadProgress = 0.3; _status = 'Uploading...'; });
      widget.onUploadProgress(widget.fileName, 0.3);

      final apiService = ApiService(host: widget.fppIp);
      final uploadResponse = await apiService.uploadVideoWithParams(
        fileBytes, widget.fileName,
        renderFps: _defaultRenderFps,
        startTime: widget.startTime, endTime: widget.endTime,
        cropRect: widget.cropRect,
      );
      if (!mounted) return;

      final uploadedFileName = uploadResponse['filename'];
      setState(() { _uploadProgress = 0.6; _status = 'Queuing render...'; });
      widget.onUploadProgress(widget.fileName, 0.6);

      await apiService.renderVideoWithParams(
        uploadedFileName,
        renderFps: _defaultRenderFps,
        startTime: widget.startTime, endTime: widget.endTime,
        cropRect: widget.cropRect,
        outputName: _nameController.text,
        brightness: widget.brightness, contrast: widget.contrast, hue: widget.hue,
      );
      if (!mounted) return;

      setState(() { _uploadProgress = 1.0; _status = 'Rendering in progress!'; });
      widget.onUploadProgress(widget.fileName, 1.0);
      final outputFileName = '${_nameController.text}.npz';
      widget.onRenderQueued(widget.fileName, outputFileName);

      await Future.delayed(const Duration(seconds: 2));
      if (mounted) {
        Navigator.of(context).pop();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Video "${_nameController.text}" is rendering'),
            backgroundColor: Colors.green,
            duration: const Duration(seconds: 3),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() { _isUploading = false; _status = 'Error: $e'; });
        widget.onUploadFailed(widget.fileName);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final duration = widget.endTime - widget.startTime;
    final cropInfo = widget.cropRect != null
        ? '${(widget.cropRect!.width * 100).toInt()}% x ${(widget.cropRect!.height * 100).toInt()}%'
        : 'None';

    return AlertDialog(
      title: const Text('Upload Video'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('File: ${_removeExtension(widget.fileName)}'),
            const SizedBox(height: 16),
            const Text('Video Name:'),
            const SizedBox(height: 8),
            TextField(
              controller: _nameController,
              decoration: const InputDecoration(
                labelText: 'Enter a name for this video',
                border: OutlineInputBorder(),
                hintText: 'e.g., "Christmas 2025"',
              ),
            ),
            const SizedBox(height: 16),
            Text('Trim: ${widget.startTime.toStringAsFixed(1)}s - ${widget.endTime.toStringAsFixed(1)}s (${duration.toStringAsFixed(1)}s)'),
            const SizedBox(height: 8),
            Text('Crop: $cropInfo'),
            if (_isUploading) ...[
              const SizedBox(height: 16),
              LinearProgressIndicator(value: _uploadProgress),
              const SizedBox(height: 12),
              Center(child: Text(_status ?? 'Processing...', style: const TextStyle(fontSize: 12), textAlign: TextAlign.center)),
            ],
          ],
        ),
      ),
      actions: [
        if (!_isUploading) TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        if (!_isUploading)
          ElevatedButton(
            onPressed: _nameController.text.isEmpty ? null : _performUpload,
            child: const Text('Upload & Render'),
          ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Scene picker dialog (for adding scenes to folders)
// ---------------------------------------------------------------------------

class _ScenePickerDialog extends StatefulWidget {
  final List<String> scenes;
  final String Function(String) displayName;
  final String Function(String) thumbnailUrl;

  const _ScenePickerDialog({
    required this.scenes,
    required this.displayName,
    required this.thumbnailUrl,
  });

  @override
  State<_ScenePickerDialog> createState() => _ScenePickerDialogState();
}

class _ScenePickerDialogState extends State<_ScenePickerDialog> {
  final Set<String> _selected = {};

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Add Scenes'),
      titlePadding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      content: SizedBox(
        width: double.maxFinite,
        height: 360,
        child: GridView.builder(
          itemCount: widget.scenes.length,
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 3,
            crossAxisSpacing: 6,
            mainAxisSpacing: 6,
            childAspectRatio: 0.85,
          ),
          itemBuilder: (ctx, i) {
            final scene = widget.scenes[i];
            final selected = _selected.contains(scene);
            return GestureDetector(
              onTap: () => setState(() {
                if (selected) { _selected.remove(scene); } else { _selected.add(scene); }
              }),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 150),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: selected ? Colors.cyanAccent : Colors.white12,
                    width: selected ? 2 : 1,
                  ),
                  color: selected ? Colors.cyan.withValues(alpha: 0.15) : Colors.grey[850],
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(
                      child: ClipRRect(
                        borderRadius: const BorderRadius.vertical(top: Radius.circular(7)),
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            Container(
                              color: Colors.black,
                              child: Image.network(
                                widget.thumbnailUrl(scene),
                                fit: BoxFit.cover,
                                gaplessPlayback: true,
                                errorBuilder: (_, __, ___) => Container(
                                  color: Colors.grey[800],
                                  child: const Icon(Icons.movie, size: 28, color: Colors.white24),
                                ),
                              ),
                            ),
                            if (selected)
                              Container(
                                color: Colors.cyan.withValues(alpha: 0.25),
                                child: const Center(child: Icon(Icons.check_circle, color: Colors.cyanAccent, size: 28)),
                              ),
                          ],
                        ),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 3),
                      child: Text(
                        widget.displayName(scene),
                        maxLines: 1, overflow: TextOverflow.ellipsis, textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 10,
                          color: selected ? Colors.cyanAccent : Colors.white70,
                          fontWeight: selected ? FontWeight.bold : FontWeight.normal,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        ElevatedButton.icon(
          onPressed: _selected.isEmpty ? null : () => Navigator.pop(context, _selected.toList()),
          icon: const Icon(Icons.add, size: 16),
          label: Text(_selected.isEmpty ? 'Add' : 'Add ${_selected.length} scene${_selected.length == 1 ? '' : 's'}'),
          style: ElevatedButton.styleFrom(
            backgroundColor: Colors.cyan,
            foregroundColor: Colors.black,
            disabledBackgroundColor: Colors.grey[700],
          ),
        ),
      ],
    );
  }
}
