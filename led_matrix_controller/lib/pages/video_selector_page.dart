import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
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

  @override
  Widget build(BuildContext context) {
    final fppIp = ref.watch(fppIpProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Scenes'),
        centerTitle: true,
        actions: [
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
                                            size: 4.8,
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
