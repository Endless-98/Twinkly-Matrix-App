import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:file_picker/file_picker.dart';
import '../services/api_service.dart';
import '../providers/app_state.dart';

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
      final fileBytes = file.bytes;

      if (fileBytes == null) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Could not read file'),
              backgroundColor: Colors.red,
            ),
          );
        }
        return;
      }

      if (mounted) {
        // Show upload dialog
        _showUploadDialog(fileName, fileBytes);
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

  void _showUploadDialog(String fileName, List<int> fileBytes) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext context) {
        return _UploadDialogContent(
          fileName: fileName,
          fileBytes: fileBytes,
          selectedRenderFps: _selectedRenderFps,
          fppIp: ref.read(fppIpProvider),
          onRenderFpsChanged: (fps) {
            setState(() {
              _selectedRenderFps = fps;
            });
          },
          onUploadComplete: () {
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
                            : _scenes.isEmpty
                                ? const Center(child: Text('No scenes found'))
                                : ListView.builder(
                                    shrinkWrap: true,
                                    physics: const NeverScrollableScrollPhysics(),
                                    itemCount: _scenes.length,
                                    itemBuilder: (context, index) {
                                      final scene = _scenes[index];
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
                                          trailing: IconButton(
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
  final String fileName;
  final List<int> fileBytes;
  final int selectedRenderFps;
  final String fppIp;
  final Function(int) onRenderFpsChanged;
  final VoidCallback onUploadComplete;

  const _UploadDialogContent({
    required this.fileName,
    required this.fileBytes,
    required this.selectedRenderFps,
    required this.fppIp,
    required this.onRenderFpsChanged,
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
      _status = 'Uploading...';
      _uploadProgress = 0.3;
    });

    try {
      final apiService = ApiService(host: widget.fppIp);

      // Upload the video
      setState(() {
        _uploadProgress = 0.3;
        _status = 'Uploading to device...';
      });

      final uploadResponse = await apiService.uploadVideo(
        widget.fileBytes,
        widget.fileName,
        renderFps: _renderFps,
      );

      if (!mounted) return;

      final uploadedFileName = uploadResponse['filename'];

      setState(() {
        _uploadProgress = 0.6;
        _status = 'Queuing render job...';
      });

      // Request rendering
      await apiService.renderVideo(
        uploadedFileName,
        renderFps: _renderFps,
      );

      if (!mounted) return;

      setState(() {
        _uploadProgress = 1.0;
        _status =
            'Rendering in progress! Video will appear in the list when ready.';
      });

      // Wait a moment then close
      await Future.delayed(const Duration(seconds: 2));

      if (mounted) {
        Navigator.of(context).pop();
        widget.onUploadComplete();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Video "${widget.fileName}" is rendering at $_renderFps FPS',
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
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Upload Video'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('File: ${widget.fileName}'),
            const SizedBox(height: 12),
            Text('Size: ${(widget.fileBytes.length / (1024 * 1024)).toStringAsFixed(2)} MB'),
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

