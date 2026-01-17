import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:file_picker/file_picker.dart';
import 'dart:async';
import 'dart:io' as io;
import '../services/api_service.dart';
import '../providers/app_state.dart';
import '../widgets/video_editor_dialog.dart';
import '../widgets/rendered_video_trimmer_dialog.dart';

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
  
  // Upload progress tracking
  final Map<String, double> _uploadProgress = {}; // filename -> progress (0.0 to 1.0)
  final Set<String> _uploadingFiles = {};
  final Set<String> _renderingFiles = {};
  final Map<String, double> _renderProgress = {}; // filename -> render progress (0.0 to 1.0)
  final Map<String, int> _renderFramesCurrent = {}; // filename -> frames rendered
  final Map<String, int> _renderFramesTotal = {}; // filename -> total frames
  Timer? _renderCheckTimer;
  final ScrollController _scrollController = ScrollController();
  final Map<String, GlobalKey> _itemKeys = {};
  String? _pendingHighlight;
  String? _activeHighlight;
  Timer? _highlightTimer;

  /// Remove file extensions from display names
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
    _scrollController.dispose();
    super.dispose();
  }

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
      setState(() {
        _scenes = scenes;
        _isLoading = false;

        final newItems = scenes.where((s) => !previousScenes.contains(s)).toList();
        if (newItems.isNotEmpty) {
          _pendingHighlight ??= newItems.first;
        }
        
        // If still rendering, start periodic checks; otherwise stop timer
        if (_renderingFiles.isNotEmpty) {
          _startRenderCheckTimer();
        } else {
          _renderCheckTimer?.cancel();
          _renderCheckTimer = null;
        }
      });
      _scheduleHighlightScroll();
    } catch (e) {
      setState(() {
        _error = e.toString();
        _isLoading = false;
      });
    }
  }

  void _startRenderCheckTimer() {
    if (_renderCheckTimer?.isActive ?? false) return; // Already running
    _renderCheckTimer = Timer.periodic(const Duration(seconds: 2), (_) async {
      if (_renderingFiles.isNotEmpty && mounted) {
        // Update progress for each rendering file
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
              
              // If complete or error, remove from rendering and mark for refresh
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
          } catch (e) {
            // Ignore progress fetch errors
          }
        }
        
        // Only refresh the video list if at least one render completed
        if (anyCompleted) {
          await _loadScenes();
        }
        
        // Stop timer if no more rendering files
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
      // Item not in view yet; try again on next frame
      WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToHighlight());
      return;
    }

    _pendingHighlight = null;
    _activeHighlight = target;
    _highlightTimer?.cancel();
    _highlightTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) {
        setState(() {
          _activeHighlight = null;
        });
      }
    });

    Scrollable.ensureVisible(
      key!.currentContext!,
      alignment: 0.2,
      duration: const Duration(milliseconds: 500),
      curve: Curves.easeInOut,
    );

    setState(() {});
  }

  Future<void> _playScene(String sceneName) async {
    try {
      final fppIp = ref.read(fppIpProvider);
      final apiService = ApiService(host: fppIp);
      await apiService.playVideo(
        sceneName,
        loop: _isLooping,
        brightness: _brightness,
        playbackFps: _playbackFps,
      );
      setState(() {
        _currentlyPlaying = sceneName;
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Playing: $sceneName')),
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
      setState(() {
        _currentlyPlaying = null;
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Playback stopped')),
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

  Future<void> _deleteVideo(String videoName) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Video'),
        content: Text('Are you sure you want to delete "${_displayName(videoName)}"?\n\nThis action cannot be undone.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
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
          SnackBar(
            content: Text('Deleted $videoName'),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to delete video: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Future<void> _trimVideo(String videoName) async {
    // Check if this is a rendered video (.npz)
    final isRenderedVideo = videoName.endsWith('.npz');
    
    if (isRenderedVideo) {
      // Use the rendered video trimmer dialog
      final fppIp = ref.read(fppIpProvider);
      final apiService = ApiService(host: fppIp);
      
      try {
        // Get video metadata
        final metadata = await apiService.getRenderedVideoMeta(videoName);
        final duration = (metadata['duration'] as num).toDouble();
        final totalFrames = (metadata['frames'] as num).toInt();
        final fps = (metadata['fps'] as num).toDouble();
        
        if (!mounted) return;
        
        // Show the rendered video trimmer dialog
        final confirmed = await showDialog<bool>(
          context: context,
          barrierDismissible: false,
          builder: (context) => RenderedVideoTrimmerDialog(
            videoPath: '', // Not used for rendered videos
            fileName: videoName,
            duration: duration,
            totalFrames: totalFrames,
            fps: fps,
            apiHost: fppIp,
            onConfirm: (startTime, endTime) {
              Navigator.of(context).pop(true);
              _performTrim(videoName, startTime, endTime);
            },
          ),
        );
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Failed to load video metadata: $e'),
              backgroundColor: Colors.red,
            ),
          );
        }
      }
    }
  }

  Future<void> _performTrim(
    String videoName,
    double startTime,
    double endTime,
  ) async {
    final fppIp = ref.read(fppIpProvider);
    final apiService = ApiService(host: fppIp);
    
    try {
      // Extract base name without extension
      final baseName = videoName.contains('.')
          ? videoName.substring(0, videoName.lastIndexOf('.'))
          : videoName;
      final outputName = '${baseName}_trim.npz';

      _pendingHighlight = outputName;

      await apiService.trimRenderedVideo(
        videoName,
        startTime: startTime,
        endTime: endTime,
        outputName: outputName,
      );

      await _loadScenes();

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Trimmed $videoName'),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to trim video: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Future<void> _renameVideo(String videoName) async {
    String newName = _displayName(videoName);
    final renameController = TextEditingController(text: _displayName(videoName));
    
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Rename Video'),
        content: TextField(
          controller: renameController,
          onChanged: (value) {
            newName = value;
          },
          decoration: InputDecoration(
            labelText: 'New name',
            hintText: _displayName(videoName),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Rename'),
          ),
        ],
      ),
    );

    renameController.dispose();
    
    if (confirmed != true || newName == _displayName(videoName)) return;
    
    try {
      final fppIp = ref.read(fppIpProvider);
      final apiService = ApiService(host: fppIp);
      await apiService.renameVideo(videoName, newName);
      await _loadScenes();
      
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Renamed to $newName'),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to rename video: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Future<void> _uploadAndRenderVideo() async {
    final choice = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Add Video'),
        content: const Text('How would you like to add a video?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop('local'),
            child: const Text('Upload from Device'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(context).pop('youtube'),
            child: const Text('Download from YouTube'),
          ),
        ],
      ),
    );

    if (choice == null) return;
    if (choice == 'local') {
      await _pickLocalVideo();
    } else if (choice == 'youtube') {
      await _downloadYouTubeVideo();
    }
  }

  Future<void> _pickLocalVideo() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.video,
        allowMultiple: false,
      );

      if (result == null) return;

      final file = result.files.single;
      final fileName = file.name;
      final filePath = file.path;

      if (filePath == null) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Could not access file path'),
              backgroundColor: Colors.red,
            ),
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
            onConfirm: (startTime, endTime, cropRect) {
              _showUploadDialog(filePath, fileName, startTime, endTime, cropRect);
            },
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error picking file: $e'),
            backgroundColor: Colors.red,
          ),
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
            onChanged: (value) {
              setState(() {
                youtubeUrl = value.trim();
              });
            },
            decoration: const InputDecoration(
              labelText: 'YouTube URL',
              hintText: 'https://www.youtube.com/watch?v=...',
              border: OutlineInputBorder(),
            ),
            maxLines: 2,
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: youtubeUrl.isNotEmpty ? () => Navigator.of(context).pop(true) : null,
              child: const Text('Download'),
            ),
          ],
        ),
      ),
    );

    if (confirmed != true || youtubeUrl.isEmpty) return;
    if (!mounted) return;

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: const Text('Downloading Video'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: const [
            CircularProgressIndicator(),
            SizedBox(height: 16),
            Text('This may take a few minutes...'),
          ],
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

      // Show progress dialog while downloading to device
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
                    Text(
                      '${(downloadProgress * 100).toStringAsFixed(1)}%',
                      style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      downloadStatus,
                      style: const TextStyle(fontSize: 12),
                      textAlign: TextAlign.center,
                    ),
                  ],
                ),
              );
            }
          ),
        );
      }

      // Download file to local device storage with progress tracking
      try {
        final localFilePath = await apiService.downloadVideoLocally(
          fileName,
          onProgress: (received, total) {
            if (total > 0 && mounted) {
              downloadProgress = received / total;
              final receivedMB = (received / 1024 / 1024).toStringAsFixed(1);
              final totalMB = (total / 1024 / 1024).toStringAsFixed(1);
              downloadStatus = 'Downloading: $receivedMB MB / $totalMB MB';
              try {
                downloadStateSetter(() {});
              } catch (e) {
                // State setter might fail if dialog was closed
              }
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
              onConfirm: (startTime, endTime, cropRect) {
                _showUploadDialog(localFilePath, fileName, startTime, endTime, cropRect);
              },
            ),
          );
        }
      } catch (e) {
        if (!mounted) return;
        Navigator.of(context).pop();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to download video: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } catch (e) {
      if (!mounted) return;
      Navigator.of(context).pop();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Failed to download YouTube video: $e'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  void _showUploadDialog(
    String filePath,
    String fileName,
    double startTime,
    double endTime,
    Rect? cropRect,
  ) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext context) {
        return _UploadDialogContent(
          filePath: filePath,
          fileName: fileName,
          startTime: startTime,
          endTime: endTime,
          cropRect: cropRect,
          fppIp: ref.read(fppIpProvider),
          onUploadStarted: (uploadFileName) {
            setState(() {
              _uploadingFiles.add(uploadFileName);
              _uploadProgress[uploadFileName] = 0.0;
            });
          },
          onUploadProgress: (uploadFileName, progress) {
            setState(() {
              _uploadProgress[uploadFileName] = progress;
            });
          },
          onRenderQueued: (originalFileName, outputFileName) {
            setState(() {
              _uploadingFiles.remove(originalFileName);
              _uploadProgress.remove(originalFileName);
              _renderingFiles.add(outputFileName);
              // Start polling timer if not already running
              if (_renderCheckTimer == null || !(_renderCheckTimer?.isActive ?? false)) {
                _startRenderCheckTimer();
              }
            });
            // Don't call _loadScenes() here - let the timer handle refresh
            // This prevents premature removal of rendering status
          },
          onUploadFailed: (uploadFileName) {
            setState(() {
              _uploadingFiles.remove(uploadFileName);
              _uploadProgress.remove(uploadFileName);
              _renderingFiles.remove(uploadFileName);
            });
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final fppIp = ref.watch(fppIpProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Scenes'),
        centerTitle: true,
        actions: [
          IconButton(
            icon: const Icon(Icons.add),
            tooltip: 'Upload new video',
            onPressed: _uploadAndRenderVideo,
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _loadScenes,
          ),
        ],
      ),
      body: LayoutBuilder(
        builder: (context, constraints) {
          return SingleChildScrollView(
            controller: _scrollController,
            padding: const EdgeInsets.only(bottom: 16),
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: constraints.maxHeight),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(16),
                    color: Colors.grey[800],
                    child: Text(
                      'Connected to: $fppIp:5000',
                      style: TextStyle(fontSize: 12, color: Colors.grey[400]),
                      textAlign: TextAlign.center,
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                    color: Colors.grey[850],
                    child: Row(
                      children: [
                        Checkbox(
                          value: _isLooping,
                          onChanged: (value) {
                            setState(() {
                              _isLooping = value ?? true;
                            });
                          },
                        ),
                        const Text('Loop'),
                        const SizedBox(width: 24),
                        const Text('Brightness:'),
                        Expanded(
                          child: Slider(
                            value: _brightness,
                            min: 0.1,
                            max: 1.5,
                            divisions: 14,
                            label: '${(_brightness * 100).round()}%',
                            onChanged: (value) {
                              setState(() {
                                _brightness = value;
                              });
                            },
                          ),
                        ),
                        Text('${(_brightness * 100).round()}%'),
                      ],
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
                    child: _isLoading
                        ? const Center(child: CircularProgressIndicator())
                        : _error != null
                            ? Column(
                                children: [
                                  const Icon(Icons.error, size: 48, color: Colors.red),
                                  const SizedBox(height: 12),
                                  Text('Error: $_error'),
                                  const SizedBox(height: 12),
                                  ElevatedButton(
                                    onPressed: _loadScenes,
                                    child: const Text('Retry'),
                                  ),
                                ],
                              )
                            : _scenes.isEmpty && _uploadingFiles.isEmpty && _renderingFiles.isEmpty
                                ? const Center(child: Text('No scenes found'))
                                : Builder(
                                    builder: (context) {
                                      final uploadingList = _uploadingFiles.toList()..sort();
                                      final renderingList = _renderingFiles.toList()..sort();
                                      
                                      // Combine all items for grid display
                                      final allItems = <({String name, String type, double? progress})>[
                                        ...uploadingList.map((f) => (name: f, type: 'uploading', progress: _uploadProgress[f] ?? 0.0)),
                                        ...renderingList.map((f) => (name: f, type: 'rendering', progress: null)),
                                        ..._scenes.map((s) => (name: s, type: 'scene', progress: null)),
                                      ];

                                      return GridView.builder(
                                        shrinkWrap: true,
                                        physics: const NeverScrollableScrollPhysics(),
                                        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                                          crossAxisCount: 2,
                                          crossAxisSpacing: 12,
                                          mainAxisSpacing: 12,
                                          childAspectRatio: 1.0,
                                        ),
                                        padding: const EdgeInsets.symmetric(horizontal: 8),
                                        itemCount: allItems.length,
                                        itemBuilder: (context, index) {
                                          final item = allItems[index];
                                          
                                          if (item.type == 'uploading') {
                                            return _buildUploadingCard(item.name, item.progress!);
                                          } else if (item.type == 'rendering') {
                                            return _buildRenderingCard(item.name);
                                          } else {
                                            final key = _itemKeys.putIfAbsent(item.name, () => GlobalKey());
                                            final isHighlighted = _activeHighlight == item.name;
                                            return KeyedSubtree(
                                              key: key,
                                              child: _buildSceneCard(item.name, isHighlighted: isHighlighted),
                                            );
                                          }
                                        },
                                      );
                                    },
                                  ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  /// Build a square card for an uploading video
  Widget _buildUploadingCard(String fileName, double progress) {
    return Card(
      color: Colors.orange[900],
      child: Stack(
        fit: StackFit.expand,
        children: [
          // Background placeholder
          Container(
            color: Colors.orange[800],
            child: const Center(
              child: Icon(Icons.cloud_upload, size: 48, color: Colors.white30),
            ),
          ),
          // Progress overlay
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
                      const CircularProgressIndicator(color: Colors.white),
                      const SizedBox(height: 12),
                      Text(
                        _displayName(fileName),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                        textAlign: TextAlign.center,
                      ),
                    ],
                  ),
                ),
                LinearProgressIndicator(
                  value: progress,
                  backgroundColor: Colors.white24,
                  minHeight: 4,
                ),
                const SizedBox(height: 4),
                Center(
                  child: Text(
                    '${(progress * 100).toInt()}%',
                    style: const TextStyle(color: Colors.white, fontSize: 12),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Build a square card for a rendering video
  Widget _buildRenderingCard(String fileName) {
    final progress = _renderProgress[fileName] ?? 0.0;
    final percentage = (progress * 100).toStringAsFixed(0);
    final framesRendered = _renderFramesCurrent[fileName] ?? 0;
    final totalFrames = _renderFramesTotal[fileName] ?? 0;
    
    // Build status text based on available data
    String statusText;
    if (totalFrames > 0) {
      statusText = '$framesRendered / $totalFrames frames';
    } else if (progress > 0) {
      statusText = 'Rendering $percentage%...';
    } else {
      statusText = 'Starting render...';
    }
    
    return Card(
      color: Colors.blueGrey[900],
      child: Stack(
        fit: StackFit.expand,
        children: [
          // Darker background with rendering icon
          Container(
            color: Colors.blueGrey[900],
            child: const Center(
              child: Icon(Icons.hourglass_bottom, size: 48, color: Colors.white30),
            ),
          ),
          // Rendering progress overlay
          Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                const Spacer(),
                // Progress indicator
                SizedBox(
                  width: 60,
                  height: 60,
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      SizedBox(
                        width: 60,
                        height: 60,
                        child: CircularProgressIndicator(
                          value: progress > 0 ? progress : null,
                          strokeWidth: 4,
                          color: Colors.white,
                          backgroundColor: Colors.white24,
                        ),
                      ),
                      Text(
                        '$percentage%',
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                          fontSize: 14,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  _displayName(fileName),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 8),
                Text(
                  statusText,
                  style: const TextStyle(color: Colors.white70, fontSize: 12),
                ),
                const SizedBox(height: 4),
                // Progress bar at bottom
                LinearProgressIndicator(
                  value: progress > 0 ? progress : null,
                  backgroundColor: Colors.white24,
                  valueColor: const AlwaysStoppedAnimation<Color>(Colors.blue),
                  minHeight: 4,
                ),
                const Spacer(),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Build a square card for a completed scene
  Widget _buildSceneCard(String sceneName, {bool isHighlighted = false}) {
    final isPlaying = _currentlyPlaying == sceneName;
    final fppIp = ref.read(fppIpProvider);
    final apiService = ApiService(host: fppIp);
    final thumbnailUrl = apiService.getThumbnailUrl(sceneName);

    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      decoration: BoxDecoration(
        border: isHighlighted
            ? Border.all(color: Colors.blueAccent, width: 3)
            : null,
        boxShadow: isHighlighted
            ? [
                BoxShadow(
                  color: Colors.blueAccent.withOpacity(0.5),
                  blurRadius: 12,
                  spreadRadius: 2,
                ),
              ]
            : null,
      ),
      child: Card(
        color: isPlaying
            ? Colors.green[900]
            : isHighlighted
                ? Colors.blueGrey[700]
                : Colors.grey[800],
      child: Stack(
        fit: StackFit.expand,
        children: [
          // Thumbnail or default background
          Image.network(
            thumbnailUrl,
            fit: BoxFit.cover,
            errorBuilder: (context, error, stackTrace) {
              // Fallback to default icon if thumbnail doesn't exist or fails to load
              return Container(
                color: Colors.grey[700],
                child: Center(
                  child: Icon(
                    Icons.movie,
                    size: 48,
                    color: Colors.grey[500],
                  ),
                ),
              );
            },
            loadingBuilder: (context, child, loadingProgress) {
              if (loadingProgress == null) {
                return child;
              }
              return Container(
                color: Colors.grey[700],
                child: Center(
                  child: CircularProgressIndicator(
                    value: loadingProgress.expectedTotalBytes != null
                        ? loadingProgress.cumulativeBytesLoaded / loadingProgress.expectedTotalBytes!
                        : null,
                  ),
                ),
              );
            },
          ),
          // Dark overlay for better text visibility
          Container(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Colors.black.withOpacity(0.6),
                  Colors.black.withOpacity(0.3),
                  Colors.black.withOpacity(0.6),
                ],
              ),
            ),
          ),
          // Overlay with title and controls
          Padding(
            padding: const EdgeInsets.all(8),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                // Title at top
                Text(
                  _displayName(sceneName),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 13,
                    shadows: [
                      Shadow(
                        offset: Offset(1, 1),
                        blurRadius: 3,
                        color: Colors.black,
                      ),
                    ],
                  ),
                  textAlign: TextAlign.center,
                ),
                // Controls at bottom
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    // Play/Stop button
                    Material(
                      color: isPlaying ? Colors.red : Colors.green,
                      shape: const CircleBorder(),
                      child: InkWell(
                        onTap: () {
                          if (isPlaying) {
                            _stopPlayback();
                          } else {
                            _playScene(sceneName);
                          }
                        },
                        child: Padding(
                          padding: const EdgeInsets.all(8),
                          child: Icon(
                            isPlaying ? Icons.stop : Icons.play_arrow,
                            color: Colors.white,
                            size: 24,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    // Menu button
                    PopupMenuButton<String>(
                      onSelected: (value) {
                        if (value == 'trim') {
                          _trimVideo(sceneName);
                        } else if (value == 'rename') {
                          _renameVideo(sceneName);
                        } else if (value == 'delete') {
                          _deleteVideo(sceneName);
                        }
                      },
                      itemBuilder: (BuildContext context) => [
                        const PopupMenuItem(
                          value: 'trim',
                          child: Row(
                            children: [
                              Icon(Icons.cut, size: 18),
                              SizedBox(width: 8),
                              Text('Trim'),
                            ],
                          ),
                        ),
                        const PopupMenuItem(
                          value: 'rename',
                          child: Row(
                            children: [
                              Icon(Icons.edit, size: 18),
                              SizedBox(width: 8),
                              Text('Rename'),
                            ],
                          ),
                        ),
                        const PopupMenuItem(
                          value: 'delete',
                          child: Row(
                            children: [
                              Icon(Icons.delete, size: 18, color: Colors.red),
                              SizedBox(width: 8),
                              Text('Delete', style: TextStyle(color: Colors.red)),
                            ],
                          ),
                        ),
                      ],
                      color: Colors.grey[900],
                      child: Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: Colors.black.withOpacity(0.5),
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(Icons.more_vert, color: Colors.white, size: 20),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          // Green playing indicator
          if (isPlaying)
            Positioned(
              top: 4,
              right: 4,
              child: Container(
                width: 12,
                height: 12,
                decoration: const BoxDecoration(
                  color: Colors.green,
                  shape: BoxShape.circle,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _UploadDialogContent extends StatefulWidget {
  final String filePath;
  final String fileName;
  final double startTime;
  final double endTime;
  final Rect? cropRect;
  final String fppIp;
  final Function(String) onUploadStarted;
  final Function(String, double) onUploadProgress;
  final Function(String, String) onRenderQueued;  // (originalFileName, outputFileName)
  final Function(String) onUploadFailed;

  const _UploadDialogContent({
    required this.filePath,
    required this.fileName,
    required this.startTime,
    required this.endTime,
    required this.cropRect,
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
  static const int _defaultRenderFps = 20; // Default FPS for all renders

  @override
  void initState() {
    super.initState();
    // Initialize video name from filename without extension
    _nameController = TextEditingController(text: _removeExtension(widget.fileName));
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  String _removeExtension(String filename) {
    final lastDot = filename.lastIndexOf('.');
    if (lastDot != -1) {
      return filename.substring(0, lastDot);
    }
    return filename;
  }

  Future<void> _performUpload() async {
    setState(() {
      _isUploading = true;
      _status = 'Reading file...';
      _uploadProgress = 0.1;
    });

    // Notify parent that upload started
    widget.onUploadStarted(widget.fileName);

    try {
      // Read file bytes
      final file = io.File(widget.filePath);
      final fileBytes = await file.readAsBytes();

      if (!mounted) return;

      setState(() {
        _uploadProgress = 0.3;
        _status = 'Uploading to device...';
      });
      widget.onUploadProgress(widget.fileName, 0.3);

      final apiService = ApiService(host: widget.fppIp);

      // Upload the video with trim/crop parameters
      final uploadResponse = await apiService.uploadVideoWithParams(
        fileBytes,
        widget.fileName,
        renderFps: _defaultRenderFps,
        startTime: widget.startTime,
        endTime: widget.endTime,
        cropRect: widget.cropRect,
      );

      if (!mounted) return;

      final uploadedFileName = uploadResponse['filename'];

      setState(() {
        _uploadProgress = 0.6;
        _status = 'Queuing render job...';
      });
      widget.onUploadProgress(widget.fileName, 0.6);

      // Request rendering with trim/crop parameters
      await apiService.renderVideoWithParams(
        uploadedFileName,
        renderFps: _defaultRenderFps,
        startTime: widget.startTime,
        endTime: widget.endTime,
        cropRect: widget.cropRect,
        outputName: _nameController.text,
      );

      if (!mounted) return;

      setState(() {
        _uploadProgress = 1.0;
        _status =
            'Rendering in progress! Video will appear in the list when ready.';
      });
      widget.onUploadProgress(widget.fileName, 1.0);
      // Track the rendering by the actual output name, not the original filename
      final outputFileName = '${_nameController.text}.npz';
      widget.onRenderQueued(widget.fileName, outputFileName);

      // Wait a moment then close
      await Future.delayed(const Duration(seconds: 2));

      if (mounted) {
        Navigator.of(context).pop();
        
        final duration = widget.endTime - widget.startTime;
        final cropInfo = widget.cropRect != null 
            ? ' (cropped ${(widget.cropRect!.width * 100).toInt()}×${(widget.cropRect!.height * 100).toInt()}%)'
            : '';
        
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Video "${_nameController.text}" is rendering (${duration.toStringAsFixed(1)}s$cropInfo)',
            ),
            backgroundColor: Colors.green,
            duration: const Duration(seconds: 3),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isUploading = false;
          _status = 'Error: $e';
        });
        widget.onUploadFailed(widget.fileName);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final duration = widget.endTime - widget.startTime;
    final cropInfo = widget.cropRect != null
        ? '${(widget.cropRect!.width * 100).toInt()}% × ${(widget.cropRect!.height * 100).toInt()}%'
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
              Center(
                child: Text(
                  _status ?? 'Processing...',
                  style: const TextStyle(fontSize: 12),
                  textAlign: TextAlign.center,
                ),
              ),
            ],
          ],
        ),
      ),
      actions: [
        if (!_isUploading)
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
        if (!_isUploading)
          ElevatedButton(
            onPressed: _nameController.text.isEmpty ? null : _performUpload,
            child: const Text('Upload & Render'),
          ),
      ],
    );
  }
}

