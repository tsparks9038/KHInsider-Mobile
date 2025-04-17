import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:html/parser.dart' as html_parser;
import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';
import 'package:audio_service/audio_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  runApp(const SearchApp());
}

class SearchApp extends StatelessWidget {
  const SearchApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(home: AudioServiceWidget(child: const SearchScreen()));
  }
}

// Audio Handler for audio_service
class MyAudioHandler extends BaseAudioHandler with QueueHandler, SeekHandler {
  final _player = AudioPlayer();
  List<Song> _songs = [];
  int _currentIndex = 0;
  final Future<String> Function(String)
  fetchMp3Url; // Callback to fetch MP3 URL

  MyAudioHandler({required this.fetchMp3Url}) {
    // In _player.playbackEventStream.listen
    _player.playbackEventStream.listen((event) {
      final playing = _player.playing;
      _updatePlaybackState(
        playing: playing,
        controls: [
          MediaControl.skipToPrevious,
          playing ? MediaControl.pause : MediaControl.play,
          MediaControl.skipToNext,
          MediaControl.stop,
        ],
        updatePosition: _player.position,
        bufferedPosition: _player.bufferedPosition,
        speed: _player.speed,
        queueIndex: _currentIndex,
      );
    });

    // In _player.positionStream.listen
    _player.positionStream.listen((position) {
      _updatePlaybackState(updatePosition: position);
    });

    _player.durationStream.listen((duration) {
      final index = _currentIndex;
      if (index >= 0 && index < queue.value.length) {
        final newQueue = List<MediaItem>.from(queue.value);
        newQueue[index] = newQueue[index].copyWith(duration: duration);
        queue.add(newQueue);
      }
    });

    _player.playerStateStream.listen((state) {
      if (state.processingState == ProcessingState.completed) {
        skipToNext();
      }
    });
  }

  // In MyAudioHandler
  void _updatePlaybackState({
    bool? playing,
    List<MediaControl>? controls,
    AudioProcessingState? processingState,
    Duration? updatePosition,
    Duration? bufferedPosition,
    double? speed,
    int? queueIndex,
  }) {
    playbackState.add(
      PlaybackState(
        controls: controls ?? playbackState.value.controls,
        systemActions: playbackState.value.systemActions,
        androidCompactActionIndices:
            playbackState.value.androidCompactActionIndices,
        processingState: processingState ?? playbackState.value.processingState,
        playing: playing ?? playbackState.value.playing,
        updatePosition: updatePosition ?? playbackState.value.updatePosition,
        bufferedPosition:
            bufferedPosition ?? playbackState.value.bufferedPosition,
        speed: speed ?? playbackState.value.speed,
        queueIndex: queueIndex ?? playbackState.value.queueIndex,
      ),
    );
  }

  Future<void> setSongs(
    List<Song> songs,
    int index,
    String albumImageUrl,
  ) async {
    debugPrint('setSongs: index=$index, songCount=${songs.length}');
    _songs = songs;
    _currentIndex = index;
    final mediaItems =
        songs
            .asMap()
            .entries
            .map(
              (entry) => MediaItem(
                id: entry.value.audioUrl, // Store detail page URL temporarily
                title: entry.value.songName,
                duration: _parseDuration(entry.value.runtime),
                artUri:
                    albumImageUrl.isNotEmpty ? Uri.parse(albumImageUrl) : null,
              ),
            )
            .toList();
    debugPrint('Queue populated with ${mediaItems.length} items');
    queue.add(mediaItems);
    await playSong(index);
  }

  Future<void> playSong(int index) async {
    if (index < 0 || index >= _songs.length) {
      debugPrint('Invalid index: $index, songCount=${_songs.length}');
      return;
    }
    _currentIndex = index;
    final song = _songs[index];
    debugPrint(
      'Playing song: ${song.songName}, index=$index, url=${song.audioUrl}',
    );
    try {
      final mp3Url = await fetchMp3Url(song.audioUrl);
      debugPrint('Resolved MP3 URL: $mp3Url');
      await _player.setUrl(mp3Url);
      await play();
      // Update queue with the actual MP3 URL and duration
      final newQueue = List<MediaItem>.from(queue.value);
      newQueue[index] = newQueue[index].copyWith(
        id: mp3Url,
        duration: _player.duration ?? _parseDuration(song.runtime),
      );
      queue.add(newQueue);
      _updatePlaybackState(
        playing: true,
        processingState: AudioProcessingState.ready,
        queueIndex: index,
        updatePosition: Duration.zero,
      );
    } catch (e) {
      debugPrint('Error playing song at index $index: $e');
      if (e.toString().contains('MP3 link not found') &&
          _currentIndex < _songs.length - 1) {
        debugPrint('Skipping to next song due to MP3 link not found');
        await skipToNext();
      } else {
        _updatePlaybackState(
          playing: false,
          processingState: AudioProcessingState.error,
        );
      }
    }
  }

  @override
  Future<void> play() async {
    try {
      await _player.play();
      _updatePlaybackState(
        playing: true,
        controls: [
          MediaControl.skipToPrevious,
          MediaControl.pause,
          MediaControl.skipToNext,
          MediaControl.stop,
        ],
      );
    } catch (e) {
      debugPrint('Error during play: $e');
      _updatePlaybackState(
        playing: false,
        processingState: AudioProcessingState.error,
      );
    }
  }

  @override
  Future<void> pause() async {
    await _player.pause();
    _updatePlaybackState(
      playing: false,
      controls: [
        MediaControl.skipToPrevious,
        MediaControl.play,
        MediaControl.skipToNext,
        MediaControl.stop,
      ],
    );
  }

  @override
  Future<void> stop() async {
    await _player.stop();
    _updatePlaybackState(
      playing: false,
      processingState: AudioProcessingState.idle,
    );
    await super.stop();
  }

  @override
  Future<void> seek(Duration position) => _player.seek(position);

  @override
  Future<void> skipToNext() async {
    if (_currentIndex < _songs.length - 1) {
      await playSong(_currentIndex + 1);
    }
  }

  @override
  Future<void> skipToPrevious() async {
    if (_player.position.inSeconds > 2) {
      await _player.seek(Duration.zero);
    } else if (_currentIndex > 0) {
      await playSong(_currentIndex - 1);
    }
  }

  @override
  Future<void> skipToQueueItem(int index) async {
    await playSong(index);
  }

  Duration? _parseDuration(String runtime) {
    try {
      final parts = runtime.split(':');
      if (parts.length == 2) {
        final minutes = int.parse(parts[0]);
        final seconds = int.parse(parts[1]);
        return Duration(minutes: minutes, seconds: seconds);
      }
    } catch (e) {
      debugPrint('Error parsing duration: $e');
    }
    return null;
  }
}

class SearchScreen extends StatefulWidget {
  const SearchScreen({super.key});

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  final TextEditingController _searchController = TextEditingController();
  final http.Client _httpClient = http.Client();
  late MyAudioHandler _audioHandler;
  bool _isAudioHandlerInitialized = false;
  Timer? _debounce;

  List<Album> _albums = [];
  List<Album> _favoriteAlbums = [];
  Album? _selectedAlbum;
  List<Song> _songs = [];
  int _currentNavIndex = 0;

  String? _currentSongUrl;
  int _currentSongIndex = 0;
  bool _isPlayerExpanded = false;

  @override
  void initState() {
    super.initState();
    _initAudioHandler();
    _loadFavorites(); // Called here (line 264)
  }

  Future<void> _loadFavorites() async {
    final prefs = await SharedPreferences.getInstance();
    final favoriteUrls = prefs.getStringList('favorite_albums') ?? [];
    setState(() {
      _favoriteAlbums =
          _albums
              .where((album) => favoriteUrls.contains(album.albumUrl))
              .toList();
    });
  }

  Future<void> _initAudioHandler() async {
    try {
      _audioHandler = await AudioService.init(
        builder:
            () => MyAudioHandler(
              fetchMp3Url: (detailPageUrl) async {
                debugPrint('Fetching detail page: $detailPageUrl');
                final response = await _httpClient
                    .get(
                      Uri.parse(detailPageUrl),
                      headers: {
                        'User-Agent':
                            'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/91.0.4472.124 Safari/537.36',
                        'Accept':
                            'text/html,application/xhtml+xml,application/xml;q=0.9,image/webp,*/*;q=0.8',
                      },
                    )
                    .timeout(const Duration(seconds: 10));
                debugPrint('Response status: ${response.statusCode}');
                if (response.statusCode == 200) {
                  final document = html_parser.parse(response.body);
                  final mp3Anchor = document
                      .querySelectorAll('a')
                      .firstWhere(
                        (a) =>
                            a.attributes['href']?.toLowerCase().endsWith(
                              '.mp3',
                            ) ??
                            false,
                        orElse: () => throw Exception('MP3 link not found'),
                      );
                  final mp3Link = mp3Anchor.attributes['href']!;
                  debugPrint('Fetched MP3 URL: $mp3Link');
                  return mp3Link.startsWith('http')
                      ? mp3Link
                      : 'https://downloads.khinsider.com$mp3Link';
                }
                throw Exception(
                  'Failed to load detail page: ${response.statusCode} ${response.reasonPhrase}',
                );
              },
            ),
        config: const AudioServiceConfig(
          androidNotificationChannelId: 'com.example.app.channel.audio',
          androidNotificationChannelName: 'Music Playback',
          androidNotificationOngoing: true,
          androidShowNotificationBadge: true,
        ),
      );
      setState(() {
        _isAudioHandlerInitialized = true;
      });
    } catch (e) {
      debugPrint('Error initializing AudioHandler: $e');
      setState(() {
        _isAudioHandlerInitialized = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to initialize audio player: $e')),
      );
    }
  }

  Future<void> _toggleFavorite(Album album) async {
    final prefs = await SharedPreferences.getInstance();
    final favoriteUrls = prefs.getStringList('favorite_albums') ?? [];
    if (favoriteUrls.contains(album.albumUrl)) {
      favoriteUrls.remove(album.albumUrl);
      _favoriteAlbums.removeWhere((a) => a.albumUrl == album.albumUrl);
    } else {
      favoriteUrls.add(album.albumUrl);
      _favoriteAlbums.add(album);
    }
    await prefs.setStringList('favorite_albums', favoriteUrls);
    setState(() {});
  }

  Future<List<Album>> _fetchAlbumsAsync(String query) async {
    final prefs = await SharedPreferences.getInstance();
    final cacheKey = 'albums_$query';
    final cachedData = prefs.getString(cacheKey);

    if (cachedData != null) {
      return parseAlbumList(cachedData);
    }

    const maxRetries = 3;
    for (var attempt = 1; attempt <= maxRetries; attempt++) {
      try {
        final formattedText = query.replaceAll(' ', '+');
        final url = Uri.parse(
          'https://downloads.khinsider.com/search?search=$formattedText',
        );
        debugPrint('Fetching URL: $url (Attempt $attempt)');
        final response = await _httpClient
            .get(
              url,
              headers: {
                'User-Agent':
                    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/91.0.4472.124 Safari/537.36',
                'Accept':
                    'text/html,application/xhtml+xml,application/xml;q=0.9,image/webp,*/*;q=0.8',
              },
            )
            .timeout(const Duration(seconds: 10)); // Add timeout
        debugPrint('Response status: ${response.statusCode}');
        if (response.statusCode == 200) {
          await prefs.setString(cacheKey, response.body);
          return await compute(parseAlbumList, response.body);
        } else {
          throw Exception(
            'Failed to load albums: ${response.statusCode} ${response.reasonPhrase}',
          );
        }
      } catch (e, stackTrace) {
        debugPrint('Attempt $attempt failed: $e\nStack trace: $stackTrace');
        if (attempt == maxRetries) {
          rethrow;
        }
        await Future.delayed(Duration(seconds: attempt * 2));
      }
    }
    throw Exception('Failed to load albums after $maxRetries attempts');
  }

  Future<void> _fetchActualMp3Url(String detailPageUrl) async {
    try {
      setState(() {
        _currentSongUrl = detailPageUrl;
      });
      await _audioHandler.setSongs(
        _songs,
        _currentSongIndex,
        _selectedAlbum?.imageUrl ?? '',
      );
      setState(() {}); // Force UI rebuild
    } catch (e) {
      debugPrint('Error initiating song playback: $e');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('Failed to load song. Please try again.'),
          action: SnackBarAction(
            label: 'Retry',
            onPressed: () => _fetchActualMp3Url(detailPageUrl),
          ),
        ),
      );
    }
  }

  String _formatDuration(Duration duration) {
    final minutes = duration.inMinutes;
    final seconds = duration.inSeconds % 60;
    return '${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
  }

  Future<void> _fetchAlbumPage(String albumUrl) async {
    final fullUrl = 'https://downloads.khinsider.com$albumUrl';
    try {
      final response = await _httpClient.get(Uri.parse(fullUrl));
      if (response.statusCode == 200) {
        final imageUrl = _getHighResImageUrl(
          html_parser
                  .parse(response.body)
                  .querySelector('.albumImage img')
                  ?.attributes['src'] ??
              '',
        );
        setState(() {
          _selectedAlbum = _selectedAlbum?.copyWith(imageUrl: imageUrl);
        });
        final songs = await compute(parseSongList, response.body);
        setState(() {
          _songs = songs;
        });
      } else {
        debugPrint('Error: ${response.statusCode}');
      }
    } catch (e) {
      debugPrint('Error occurred while fetching album page: $e');
    }
  }

  String _getHighResImageUrl(String url) {
    return url.replaceFirst('/thumbs/', '/');
  }

  Widget _buildAlbumList() {
    return FutureBuilder<List<Album>>(
      future: _fetchAlbumsAsync(_searchController.text),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        } else if (snapshot.hasError) {
          return Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text('Error: ${snapshot.error}'),
                ElevatedButton(
                  onPressed: () => setState(() {}),
                  child: const Text('Retry'),
                ),
              ],
            ),
          );
        } else if (!snapshot.hasData || snapshot.data!.isEmpty) {
          return const Center(child: Text('No albums found.'));
        } else {
          _albums = snapshot.data!;
          return ListView.builder(
            itemCount: _albums.length,
            itemBuilder: (context, index) {
              final album = _albums[index];
              return ListTile(
                leading:
                    album.imageUrl.isNotEmpty
                        ? CircleAvatar(
                          backgroundImage: NetworkImage(album.imageUrl),
                          radius: 30,
                        )
                        : const CircleAvatar(
                          backgroundColor: Colors.grey,
                          radius: 30,
                          child: Icon(Icons.music_note, color: Colors.white),
                        ),
                title: Text(album.albumName),
                subtitle: Text(
                  '${album.type} - ${album.year} | ${album.platform}',
                ),
                trailing: IconButton(
                  icon: Icon(
                    _favoriteAlbums.any((fav) => fav.albumUrl == album.albumUrl)
                        ? Icons.favorite
                        : Icons.favorite_border,
                    color:
                        _favoriteAlbums.any(
                              (fav) => fav.albumUrl == album.albumUrl,
                            )
                            ? Colors.red
                            : null,
                  ),
                  onPressed: () => _toggleFavorite(album),
                ),
                onTap: () {
                  setState(() {
                    _selectedAlbum = album;
                  });
                  _fetchAlbumPage(album.albumUrl);
                },
              );
            },
          );
        }
      },
    );
  }

  Widget _buildFavoritesList() {
    return _favoriteAlbums.isEmpty
        ? const Center(child: Text('No favorite albums yet.'))
        : ListView.builder(
          itemCount: _favoriteAlbums.length,
          itemBuilder: (context, index) {
            final album = _favoriteAlbums[index];
            return ListTile(
              leading:
                  album.imageUrl.isNotEmpty
                      ? CircleAvatar(
                        backgroundImage: NetworkImage(album.imageUrl),
                        radius: 30,
                      )
                      : const CircleAvatar(
                        backgroundColor: Colors.grey,
                        radius: 30,
                        child: Icon(Icons.music_note, color: Colors.white),
                      ),
              title: Text(album.albumName),
              subtitle: Text(
                '${album.type} - ${album.year} | ${album.platform}',
              ),
              trailing: IconButton(
                icon: const Icon(Icons.favorite, color: Colors.red),
                onPressed: () => _toggleFavorite(album),
              ),
              onTap: () {
                setState(() {
                  _selectedAlbum = album;
                });
                _fetchAlbumPage(album.albumUrl);
              },
            );
          },
        );
  }

  Widget _buildSongList() {
    return ListView(
      children: [
        const SizedBox(height: 16),
        Center(
          child:
              _selectedAlbum?.imageUrl.isNotEmpty == true
                  ? ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: Image.network(
                      _selectedAlbum!.imageUrl,
                      width: 200,
                      height: 200,
                      fit: BoxFit.cover,
                    ),
                  )
                  : Container(
                    width: 200,
                    height: 200,
                    color: Colors.grey[300],
                    child: const Icon(Icons.music_note, size: 100),
                  ),
        ),
        const SizedBox(height: 12),
        Text(
          _selectedAlbum!.albumName,
          style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 4),
        Text(
          '${_selectedAlbum!.type} - ${_selectedAlbum!.year} | ${_selectedAlbum!.platform}',
          style: const TextStyle(color: Colors.grey),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 24),
        ..._songs.asMap().entries.map((entry) {
          final index = entry.key;
          final song = entry.value;
          return ListTile(
            title: Text(song.songName),
            subtitle: Text(song.runtime),
            onTap: () {
              debugPrint('Selected song: ${song.songName}, index=$index');
              setState(() {
                _currentSongIndex = index;
                _currentSongUrl = song.audioUrl;
                _isPlayerExpanded = false;
              });
              _fetchActualMp3Url(song.audioUrl);
            },
          );
        }),
      ],
    );
  }

  Widget _buildExpandedPlayer() {
    return Material(
      elevation: 12,
      color: Colors.white,
      child: StreamBuilder<PlaybackState>(
        stream: _audioHandler.playbackState.distinct(),
        builder: (context, snapshot) {
          debugPrint(
            'ExpandedPlayer StreamBuilder: queueIndex=${snapshot.data?.queueIndex}, position=${snapshot.data?.updatePosition}',
          );
          final position = snapshot.data?.updatePosition ?? Duration.zero;
          final playing = snapshot.data?.playing ?? false;
          final queueIndex = snapshot.data?.queueIndex ?? _currentSongIndex;
          final song =
              _songs.isNotEmpty && queueIndex >= 0 && queueIndex < _songs.length
                  ? _songs[queueIndex]
                  : _songs[_currentSongIndex];

          final duration =
              _audioHandler.queue.value.isNotEmpty &&
                      queueIndex >= 0 &&
                      queueIndex < _audioHandler.queue.value.length
                  ? _audioHandler.queue.value[queueIndex].duration ??
                      Duration.zero
                  : Duration.zero;

          return Container(
            key: ValueKey<int>(queueIndex), // Force rebuild on song change
            height: MediaQuery.of(context).size.height,
            width: MediaQuery.of(context).size.width,
            color: Colors.white,
            padding: const EdgeInsets.only(
              top: 40,
              left: 20,
              right: 20,
              bottom: 40,
            ),
            child: Column(
              children: [
                Align(
                  alignment: Alignment.topRight,
                  child: IconButton(
                    icon: const Icon(Icons.keyboard_arrow_down),
                    onPressed: () {
                      setState(() {
                        _isPlayerExpanded = false;
                        SystemChrome.setEnabledSystemUIMode(
                          SystemUiMode.edgeToEdge,
                        );
                      });
                    },
                  ),
                ),
                const Spacer(),
                if (_selectedAlbum?.imageUrl.isNotEmpty == true)
                  LayoutBuilder(
                    builder: (context, constraints) {
                      final imageSize = constraints.maxWidth * 0.5;
                      return ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: Image.network(
                          _selectedAlbum!.imageUrl,
                          width: imageSize,
                          height: imageSize,
                          fit: BoxFit.cover,
                        ),
                      );
                    },
                  ),
                const SizedBox(height: 20),
                Text(
                  song.songName,
                  style: const TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                  ),
                  textAlign: TextAlign.center,
                ),
                const Spacer(),
                Column(
                  children: [
                    Slider(
                      value: position.inSeconds.toDouble().clamp(
                        0.0,
                        duration.inSeconds.toDouble(),
                      ),
                      min: 0.0,
                      max: duration.inSeconds.toDouble(),
                      onChanged: (value) {
                        _audioHandler.seek(Duration(seconds: value.toInt()));
                      },
                    ),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(_formatDuration(position)),
                        Text(_formatDuration(duration)),
                      ],
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Semantics(
                      label: 'Skip to previous song',
                      child: IconButton(
                        iconSize: 40.0,
                        icon: const Icon(Icons.skip_previous),
                        onPressed: () {
                          _audioHandler.skipToPrevious();
                        },
                      ),
                    ),
                    Semantics(
                      label:
                          playing
                              ? 'Pause ${song.songName}'
                              : 'Play ${song.songName}',
                      child: IconButton(
                        iconSize: 48.0,
                        icon: Icon(playing ? Icons.pause : Icons.play_arrow),
                        onPressed: () {
                          if (playing) {
                            _audioHandler.pause();
                          } else {
                            _audioHandler.play();
                          }
                        },
                      ),
                    ),
                    Semantics(
                      label: 'Skip to next song',
                      child: IconButton(
                        iconSize: 40.0,
                        icon: const Icon(Icons.skip_next),
                        onPressed: () {
                          _audioHandler.skipToNext();
                        },
                      ),
                    ),
                  ],
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _buildMiniPlayer() {
    return Material(
      elevation: 6,
      color: Colors.white,
      child: StreamBuilder<PlaybackState>(
        stream: _audioHandler.playbackState.distinct(),
        builder: (context, snapshot) {
          debugPrint(
            'MiniPlayer StreamBuilder: playing=${snapshot.data?.playing}, queueIndex=${snapshot.data?.queueIndex}',
          );
          final playing = snapshot.data?.playing ?? false;
          final queueIndex = snapshot.data?.queueIndex ?? _currentSongIndex;
          final song =
              _songs.isNotEmpty && queueIndex >= 0 && queueIndex < _songs.length
                  ? _songs[queueIndex]
                  : null;

          return InkWell(
            onTap: () {
              setState(() {
                _isPlayerExpanded = true;
              });
            },
            child: Container(
              height: 70,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Row(
                children: [
                  if (_selectedAlbum?.imageUrl.isNotEmpty == true)
                    ClipRRect(
                      borderRadius: BorderRadius.circular(6),
                      child: Image.network(
                        _selectedAlbum!.imageUrl,
                        width: 50,
                        height: 50,
                        fit: BoxFit.cover,
                      ),
                    ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      song?.songName ?? 'Playing...',
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 16),
                    ),
                  ),
                  Semantics(
                    label: playing ? 'Pause current song' : 'Play current song',
                    child: IconButton(
                      icon: Icon(playing ? Icons.pause : Icons.play_arrow),
                      onPressed: () {
                        if (_songs.isEmpty || _selectedAlbum == null) return;
                        if (playing) {
                          _audioHandler.pause();
                        } else {
                          _audioHandler.play();
                        }
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar:
          _isPlayerExpanded
              ? null
              : AppBar(title: const Text('KHInsider Search')),
      body:
          _isAudioHandlerInitialized
              ? Stack(
                children: [
                  Padding(
                    padding: const EdgeInsets.all(16.0),
                    child: Column(
                      children: [
                        if (_selectedAlbum == null &&
                            _currentNavIndex == 0) ...[
                          TextField(
                            controller: _searchController,
                            decoration: const InputDecoration(
                              labelText: 'Search Albums',
                              border: OutlineInputBorder(),
                            ),
                            onChanged: (value) {
                              _debounce?.cancel();
                              _debounce = Timer(
                                const Duration(milliseconds: 500),
                                () {
                                  setState(() {});
                                },
                              );
                            },
                            onSubmitted: (value) {
                              _debounce?.cancel();
                              setState(() {});
                            },
                          ),
                          const SizedBox(height: 16),
                        ],
                        Expanded(
                          child:
                              _selectedAlbum == null
                                  ? (_currentNavIndex == 0
                                      ? _buildAlbumList()
                                      : _buildFavoritesList())
                                  : _buildSongList(),
                        ),
                      ],
                    ),
                  ),
                  if (_currentSongUrl != null)
                    Align(
                      alignment: Alignment.bottomCenter,
                      child: AnimatedSwitcher(
                        duration: const Duration(milliseconds: 300),
                        key: ValueKey<bool>(_isPlayerExpanded),
                        child:
                            _isPlayerExpanded
                                ? _buildExpandedPlayer()
                                : _buildMiniPlayer(),
                      ),
                    ),
                ],
              )
              : const Center(child: CircularProgressIndicator()),
      bottomNavigationBar:
          _isPlayerExpanded
              ? null
              : BottomNavigationBar(
                currentIndex: _currentNavIndex,
                onTap: (index) {
                  setState(() {
                    _currentNavIndex = index;
                    _selectedAlbum = null;
                  });
                  if (index == 1) _loadFavorites(); // Called here (line 851)
                },
                items: const [
                  BottomNavigationBarItem(
                    icon: Icon(Icons.search),
                    label: 'Search',
                  ),
                  BottomNavigationBarItem(
                    icon: Icon(Icons.favorite),
                    label: 'Favorites',
                  ),
                ],
              ),
    );
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _httpClient.close();
    _searchController.dispose();
    super.dispose();
  }
}

// Parsing Functions
List<Album> parseAlbumList(String htmlBody) {
  final document = html_parser.parse(htmlBody);
  final rows = document.querySelectorAll('table.albumList tbody tr');

  return rows
      .map((row) {
        final cols = row.querySelectorAll('td');
        if (cols.length < 5) return null;

        final albumName =
            '${cols[1].querySelector('a')?.text.trim() ?? ''} ${cols[1].querySelector('span')?.text.trim() ?? ''}';
        final platform = cols[2].text.trim();
        final type = cols[3].text.trim();
        final year = cols[4].text.trim();
        final imageUrl = cols[0].querySelector('img')?.attributes['src'] ?? '';
        final albumUrl = cols[1].querySelector('a')?.attributes['href'] ?? '';

        return Album(
          albumName.trim(),
          platform,
          type,
          year,
          imageUrl,
          albumUrl,
        );
      })
      .whereType<Album>()
      .toList();
}

List<Song> parseSongList(String htmlBody) {
  final document = html_parser.parse(htmlBody);
  final rows = document.querySelectorAll('#songlist tr');
  final songs =
      rows
          .map((row) {
            final links = row.querySelectorAll('a');
            if (links.length < 2) return null;
            final name = links[0].text.trim();
            final runtime = links[1].text.trim();
            final href = links[0].attributes['href'];
            if (href == null || name.isEmpty || runtime.isEmpty) return null;
            final songUrl = 'https://downloads.khinsider.com$href';
            debugPrint(
              'Parsed song: name=$name, runtime=$runtime, url=$songUrl',
            );
            return Song(name, runtime, songUrl);
          })
          .whereType<Song>()
          .toList();
  debugPrint('Parsed ${songs.length} songs');
  return songs;
}

// Models
class Album {
  final String albumName;
  final String platform;
  final String type;
  final String year;
  final String imageUrl;
  final String albumUrl;

  Album(
    this.albumName,
    this.platform,
    this.type,
    this.year,
    this.imageUrl,
    this.albumUrl,
  );

  Album copyWith({String? imageUrl}) {
    return Album(
      albumName,
      platform,
      type,
      year,
      imageUrl ?? this.imageUrl,
      albumUrl,
    );
  }
}

class Song {
  final String songName;
  final String runtime;
  final String audioUrl;

  Song(this.songName, this.runtime, this.audioUrl);
}
