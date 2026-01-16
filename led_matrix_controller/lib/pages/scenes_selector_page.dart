import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:file_picker/file_picker.dart';
import 'dart:io' as IO;
import '../services/api_service.dart';
import '../providers/app_state.dart';
import '../widgets/video_editor_dialog.dart';

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
  int _selectedRenderFps = 20;
  
  // Upload progress tracking
  final Map<String, double> _uploadProgress = {}; // filename -> progress (0.0 to 1.0)
  final Set<String> _uploadingFiles = {};

  @override
  void initState() {
    super.initState();
    _loadScenes();
  }

  Future<void> _loadScenes() async {
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
      });
    } catch (e) {
      setState(() {
        _error = e.toString();
        _isLoading = false;
      });
    }
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
    // Show confirmation dialog
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Video'),
        content: Text('Are you sure you want to delete "$videoName"?\n\nThis action cannot be undone.'),
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
      
      // Reload the scenes list
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

  Future<void> _uploadAndRenderVideo() async {
    try {
      // Pick a video file
      final result = await FilePicker.platform.pickFiles(
        type: FileType.video,
        allowMultiple: false,
      );

      if (result == null) {
        return; // User cancelled
      }

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
        // Show video editor dialog
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
          selectedRenderFps: _selectedRenderFps,
          fppIp: ref.read(fppIpProvider),
          onRenderFpsChanged: (fps) {
            setState(() {
              _selectedRenderFps = fps;
            });
          },
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
          onUploadComplete: (uploadFileName) {
            setState(() {
              _uploadingFiles.remove(uploadFileName);
              _uploadProgress.remove(uploadFileName);
            });
            _loadScenes(); // Refresh the scenes list
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
                            : _scenes.isEmpty && _uploadingFiles.isEmpty
                                ? const Center(child: Text('No scenes found'))
                                : ListView.builder(
                                    shrinkWrap: true,
                                    physics: const NeverScrollableScrollPhysics(),
                                    itemCount: _uploadingFiles.length + _scenes.length,
                                    itemBuilder: (context, index) {
                                      // Show uploading files first
                                      if (index < _uploadingFiles.length) {
                                        final uploadingFile = _uploadingFiles.elementAt(index);
                                        final progress = _uploadProgress[uploadingFile] ?? 0.0;
                                        return Card(
                                          margin: const EdgeInsets.symmetric(
                                            horizontal: 8,
                                            vertical: 6,
                                          ),
                                          color: Colors.orange[900],
                                          child: ListTile(
                                            leading: const CircularProgressIndicator(),
                                            title: Text(uploadingFile),
                                            subtitle: LinearProgressIndicator(value: progress),
                                            trailing: Text('${(progress * 100).toInt()}%'),
                                          ),
                                        );
                                      }
                                      
                                      // Show existing scenes
                                      final sceneIndex = index - _uploadingFiles.length;
                                      final scene = _scenes[sceneIndex];
                                      final isPlaying = _currentlyPlaying == scene;
                                      return Card(
                                        margin: const EdgeInsets.symmetric(
                                          horizontal: 8,
                                          vertical: 6,
                                        ),
                                        color: isPlaying ? Colors.green[900] : null,
                                        child: ListTile(
                                          leading: Icon(
                                            Icons.movie,
                                            color: isPlaying ? Colors.green : Colors.blue,
                                          ),
                                          title: Text(scene),
                                          trailing: Row(
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              IconButton(
                                                icon: Icon(
                                                  isPlaying ? Icons.stop : Icons.play_arrow,
                                                  color: isPlaying ? Colors.red : Colors.green,
                                                  size: 32,
                                                ),
                                                onPressed: () {
                                                  if (isPlaying) {
                                                    _stopPlayback();
                                                  } else {
                                                    _playScene(scene);
                                                  }
                                                },
                                              ),
                                              IconButton(
                                                icon: const Icon(
                                                  Icons.delete,
                                                  color: Colors.red,
                                                  size: 28,
                                                ),
                                                onPressed: () => _deleteVideo(scene),
                                              ),
                                            ],
                                          ),
                                        ),
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
}

class _UploadDialogContent extends StatefulWidget {
  final String filePath;
  final String fileName;
  final double startTime;
  final double endTime;
  final Rect? cropRect;
  final int selectedRenderFps;
  final String fppIp;
  final Function(int) onRenderFpsChanged;
  final Function(String) onUploadStarted;
  final Function(String, double) onUploadProgress;
  final Function(String) onUploadComplete;

  const _UploadDialogContent({
    required this.filePath,
    required this.fileName,
    required this.startTime,
    required this.endTime,
    required this.cropRect,
    required this.selectedRenderFps,
    required this.fppIp,
    required this.onRenderFpsChanged,
    required this.onUploadStarted,
    required this.onUploadProgress,
    required this.onUploadComplete,
  });

  @override
  State<_UploadDialogContent> createState() => _UploadDialogContentState();
}

class _UploadDialogContentState extends State<_UploadDialogContent> {
  late int _renderFps;
  bool _isUploading = false;
  String? _status;
  double _uploadProgress = 0;

  @override
  void initState() {
    super.initState();
    _renderFps = widget.selectedRenderFps;
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
      final file = IO.File(widget.filePath);
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
        renderFps: _renderFps,
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
        renderFps: _renderFps,
        startTime: widget.startTime,
        endTime: widget.endTime,
        cropRect: widget.cropRect,
      );

      if (!mounted) return;

      setState(() {
        _uploadProgress = 1.0;
        _status =
            'Rendering in progress! Video will appear in the list when ready.';
      });
      widget.onUploadProgress(widget.fileName, 1.0);

      // Wait a moment then close
      await Future.delayed(const Duration(seconds: 2));

      if (mounted) {
        Navigator.of(context).pop();
        widget.onUploadComplete(widget.fileName);
        
        final duration = widget.endTime - widget.startTime;
        final cropInfo = widget.cropRect != null 
            ? ' (cropped ${(widget.cropRect!.width * 100).toInt()}×${(widget.cropRect!.height * 100).toInt()}%)'
            : '';
        
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Video "${widget.fileName}" is rendering at $_renderFps FPS (${duration.toStringAsFixed(1)}s$cropInfo)',
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
        widget.onUploadComplete(widget.fileName); // Remove from uploading list
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
            Text('File: ${widget.fileName}'),
            const SizedBox(height: 8),
            Text('Trim: ${widget.startTime.toStringAsFixed(1)}s - ${widget.endTime.toStringAsFixed(1)}s (${duration.toStringAsFixed(1)}s)'),
            const SizedBox(height: 8),
            Text('Crop: $cropInfo'),
            const SizedBox(height: 16),
            const Text('Render FPS:'),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: SegmentedButton<int>(
                    segments: const <ButtonSegment<int>>[
                      ButtonSegment<int>(
                        value: 20,
                        label: Text('20 FPS'),
                      ),
                      ButtonSegment<int>(
                        value: 40,
                        label: Text('40 FPS'),
                      ),
                    ],
                    selected: <int>{_renderFps},
                    onSelectionChanged: (Set<int> newSelection) {
                      setState(() {
                        _renderFps = newSelection.first;
                      });
                    },
                  ),
                ),
              ],
            ),
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
            onPressed: _performUpload,
            child: const Text('Upload & Render'),
          ),
      ],
    );
  }
}

