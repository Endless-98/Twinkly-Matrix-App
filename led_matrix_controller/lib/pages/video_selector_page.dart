import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../services/api_service.dart';
import '../providers/app_state.dart';

class VideoSelectorPage extends ConsumerStatefulWidget {
  const VideoSelectorPage({super.key});

  @override
  ConsumerState<VideoSelectorPage> createState() => _VideoSelectorPageState();
}

class _VideoSelectorPageState extends ConsumerState<VideoSelectorPage> {
  List<String> _videos = [];
  bool _isLoading = true;
  String? _error;
  String? _currentlyPlaying;
  bool _isLooping = true;
  double _brightness = 1.0;
  double _playbackFps = 20.0;

  @override
  void initState() {
    super.initState();
    _loadVideos();
  }

  Future<void> _loadVideos() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      final fppIp = ref.read(fppIpProvider);
      final apiService = ApiService(host: fppIp);
      final videos = await apiService.getAvailableVideos();
      setState(() {
        _videos = videos;
        _isLoading = false;
      });
    } catch (e) {
      setState(() {
        _error = e.toString();
        _isLoading = false;
      });
    }
  }

  Future<void> _playVideo(String videoName) async {
    try {
      final fppIp = ref.read(fppIpProvider);
      final apiService = ApiService(host: fppIp);
      await apiService.playVideo(
        videoName,
        loop: _isLooping,
        brightness: _brightness,
        playbackFps: _playbackFps,
      );
      setState(() {
        _currentlyPlaying = videoName;
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Playing: $videoName')),
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

  @override
  Widget build(BuildContext context) {
    final fppIp = ref.watch(fppIpProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Video Selector'),
        centerTitle: true,
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _loadVideos,
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
                    padding: const EdgeInsets.all(16),
                    color: Colors.grey[850],
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Playback Settings',
                          style:
                              TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                        ),
                        const SizedBox(height: 12),
                        Row(
                          children: [
                            Checkbox(
                              value: _isLooping,
                              onChanged: (value) {
                                setState(() {
                                  _isLooping = value ?? true;
                                });
                              },
                            ),
                            const Text('Loop playback'),
                          ],
                        ),
                        Row(
                          children: [
                            const Text('Brightness: '),
                            Expanded(
                              child: Slider(
                                value: _brightness,
                                min: 0.1,
                                max: 1.0,
                                divisions: 9,
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
                        Row(
                          children: [
                            const Text('FPS: '),
                            Expanded(
                              child: Slider(
                                value: _playbackFps,
                                min: 10.0,
                                max: 60.0,
                                divisions: 50,
                                label: _playbackFps.toStringAsFixed(0),
                                onChanged: (value) {
                                  setState(() {
                                    _playbackFps = value;
                                  });
                                },
                              ),
                            ),
                            Text(_playbackFps.toStringAsFixed(0)),
                          ],
                        ),
                      ],
                    ),
                  ),
                  if (_currentlyPlaying != null)
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(12),
                      color: Colors.green[900],
                      child: Row(
                        children: [
                          const Icon(Icons.play_circle, color: Colors.green),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              'Now Playing: $_currentlyPlaying',
                              style: const TextStyle(fontWeight: FontWeight.bold),
                            ),
                          ),
                          IconButton(
                            icon: const Icon(Icons.stop, color: Colors.red),
                            onPressed: _stopPlayback,
                          ),
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
                                    onPressed: _loadVideos,
                                    child: const Text('Retry'),
                                  ),
                                ],
                              )
                            : _videos.isEmpty
                                ? const Center(child: Text('No videos found'))
                                : ListView.builder(
                                    shrinkWrap: true,
                                    physics: const NeverScrollableScrollPhysics(),
                                    itemCount: _videos.length,
                                    itemBuilder: (context, index) {
                                      final video = _videos[index];
                                      final isPlaying = _currentlyPlaying == video;
                                      return Card(
                                        margin: const EdgeInsets.symmetric(
                                          horizontal: 8,
                                          vertical: 6,
                                        ),
                                        color: isPlaying ? Colors.green[900] : null,
                                        child: ListTile(
                                          leading: Icon(
                                            isPlaying
                                                ? Icons.play_circle
                                                : Icons.video_library,
                                            color: isPlaying ? Colors.green : Colors.blue,
                                          ),
                                          title: Text(video),
                                          trailing: ElevatedButton(
                                            onPressed: () => _playVideo(video),
                                            style: ElevatedButton.styleFrom(
                                              backgroundColor: Colors.blue,
                                            ),
                                            child: const Text('Play'),
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
