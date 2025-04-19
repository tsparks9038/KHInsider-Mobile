import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:html/parser.dart' as html_parser;
import 'package:flutter/foundation.dart'; // for compute()
import 'package:just_audio/just_audio.dart';
import 'package:just_audio_background/just_audio_background.dart';

Future<void> main() async {
  await JustAudioBackground.init(
    androidNotificationChannelId: 'com.example.khinsider_android.channel.audio',
    androidNotificationChannelName: 'Audio playback',
    androidNotificationOngoing: true,
  );
  runApp(const SearchApp());
}

class SearchApp extends StatelessWidget {
  const SearchApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(home: SearchScreen());
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

  final AudioPlayer _player = AudioPlayer();
  String? _currentSongUrl;
  int _currentSongIndex = 0;
  bool _isPlayerExpanded = false;

  List<Map<String, String>> _albums = [];
  ConcatenatingAudioSource? _playlist;
  List<Map<String, dynamic>> _songs = []; // Stores AudioSource and runtime
  Map<String, String>? _selectedAlbum;

  @override
  void initState() {
    super.initState();
    _player.setLoopMode(LoopMode.off);
    _player.sequenceStateStream.listen((state) {
      if (state == null) return;
      final index = state.currentIndex;
      setState(() {
        _currentSongIndex = index;
        _currentSongUrl = (_playlist?.children[index] as ProgressiveAudioSource).uri.toString();
      });
    });
  }

  @override
  void dispose() {
    _player.dispose();
    _httpClient.close();
    _searchController.dispose();
    super.dispose();
  }

  Future<List<Map<String, String>>> _fetchAlbumsAsync(String query) async {
    final formattedText = query.replaceAll(' ', '+');
    final url = Uri.parse('https://downloads.khinsider.com/search?search=$formattedText');
    final response = await _httpClient.get(url);
    if (response.statusCode == 200) {
      return await compute(parseAlbumList, response.body);
    } else {
      throw Exception('Failed to load albums');
    }
  }

  void _playPause() {
    setState(() {
      if (_player.playing) {
        _player.pause();
      } else {
        _player.play();
      }
    });
  }

  Future<void> _playAudioSourceAtIndex(int index) async {
    try {
      if (_playlist == null || index >= _playlist!.length) return;
      await _player.setAudioSource(_playlist!, initialIndex: index);
      _player.play();
      setState(() {
        _currentSongIndex = index;
        _currentSongUrl = (_playlist!.children[index] as ProgressiveAudioSource).uri.toString();
      });
    } catch (e) {
      debugPrint('Error playing audio: $e');
    }
  }

  Future<String> _fetchActualMp3Url(String detailPageUrl) async {
    final response = await _httpClient.get(Uri.parse(detailPageUrl));
    if (response.statusCode == 200) {
      final document = html_parser.parse(response.body);
      final mp3Anchor = document.querySelectorAll('a').firstWhere(
        (a) => a.attributes['href']?.endsWith('.mp3') ?? false,
        orElse: () => throw Exception('MP3 link not found'),
      );
      return mp3Anchor.attributes['href']!;
    } else {
      throw Exception('Failed to load MP3 URL');
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
          html_parser.parse(response.body).querySelector('.albumImage img')?.attributes['src'] ?? '',
        );

        final albumName = _selectedAlbum?['albumName'] ?? 'Unknown';

        setState(() {
          _selectedAlbum = _selectedAlbum != null
              ? {..._selectedAlbum!, 'imageUrl': imageUrl}
              : {'imageUrl': imageUrl, 'albumName': albumName};
        });

        // Pass a serializable map to compute
        final songs = await compute(
          (input) => parseSongList(input['body']!, input['albumName']!, input['imageUrl']!),
          {
            'body': response.body,
            'albumName': albumName,
            'imageUrl': imageUrl,
          },
        );

        setState(() {
          _songs = songs;
          _playlist = ConcatenatingAudioSource(
            children: songs.map((song) => song['audioSource'] as AudioSource).toList(),
          );
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
    return FutureBuilder<List<Map<String, String>>>(
      future: _fetchAlbumsAsync(_searchController.text),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        } else if (snapshot.hasError) {
          return Center(child: Text('Error: ${snapshot.error}'));
        } else if (!snapshot.hasData || snapshot.data!.isEmpty) {
          return const Center(child: Text('No albums found.'));
        } else {
          _albums = snapshot.data!;
          return ListView.builder(
            itemCount: _albums.length,
            itemBuilder: (context, index) {
              final album = _albums[index];
              return ListTile(
                leading: album['imageUrl']!.isNotEmpty
                    ? CircleAvatar(
                        backgroundImage: NetworkImage(album['imageUrl']!),
                        radius: 30,
                      )
                    : const CircleAvatar(
                        backgroundColor: Colors.grey,
                        radius: 30,
                        child: Icon(Icons.music_note, color: Colors.white),
                      ),
                title: Text(album['albumName']!),
                subtitle: Text('${album['type']} - ${album['year']} | ${album['platform']}'),
                onTap: () {
                  setState(() {
                    _selectedAlbum = album;
                    _songs = [];
                    _playlist = null;
                    _currentSongIndex = 0;
                    _currentSongUrl = null;
                  });
                  _fetchAlbumPage(album['albumUrl']!);
                },
              );
            },
          );
        }
      },
    );
  }

  Widget _buildSongList() {
    return ListView(
      children: [
        const SizedBox(height: 16),
        Center(
          child: _selectedAlbum?['imageUrl']?.isNotEmpty == true
              ? ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: Image.network(
                    _selectedAlbum!['imageUrl']!,
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
          _selectedAlbum!['albumName']!,
          style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 4),
        Text(
          '${_selectedAlbum!['type']} - ${_selectedAlbum!['year']} | ${_selectedAlbum!['platform']}',
          style: const TextStyle(color: Colors.grey),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 24),
        ..._songs.asMap().entries.map((entry) {
          final index = entry.key;
          final song = entry.value;
          final audioSource = song['audioSource'] as ProgressiveAudioSource;
          return ListTile(
            title: Text(audioSource.tag.title ?? 'Unknown'),
            subtitle: Text(song['runtime'] ?? 'Unknown'),
            onTap: () {
              setState(() {
                _isPlayerExpanded = false;
              });
              _playAudioSourceAtIndex(index);
            },
          );
        }),
      ],
    );
  }

  Widget _buildExpandedPlayer() {
    final song = _songs[_currentSongIndex];
    final audioSource = song['audioSource'] as ProgressiveAudioSource;

    return Material(
      elevation: 12,
      color: Colors.white,
      child: Container(
        height: MediaQuery.of(context).size.height,
        width: MediaQuery.of(context).size.width,
        color: Colors.white,
        padding: const EdgeInsets.only(top: 40, left: 20, right: 20, bottom: 40),
        child: Column(
          children: [
            Align(
              alignment: Alignment.topRight,
              child: IconButton(
                icon: const Icon(Icons.keyboard_arrow_down),
                onPressed: () {
                  setState(() {
                    _isPlayerExpanded = false;
                    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
                  });
                },
              ),
            ),
            const Spacer(),
            if (_selectedAlbum?['imageUrl']?.isNotEmpty == true)
              ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: Image.network(
                  _selectedAlbum!['imageUrl']!,
                  width: 200,
                  height: 200,
                  fit: BoxFit.cover,
                ),
              ),
            const SizedBox(height: 20),
            Text(
              audioSource.tag.title ?? 'Unknown',
              style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
              textAlign: TextAlign.center,
            ),
            const Spacer(),
            StreamBuilder<Duration>(
              stream: _player.positionStream,
              builder: (context, snapshot) {
                final position = snapshot.data ?? Duration.zero;
                final duration = _player.duration ?? Duration.zero;

                return Column(
                  children: [
                    Slider(
                      value: position.inSeconds.toDouble().clamp(0.0, duration.inSeconds.toDouble()),
                      min: 0.0,
                      max: duration.inSeconds.toDouble(),
                      onChanged: (value) {
                        _player.seek(Duration(seconds: value.toInt()));
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
                );
              },
            ),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                IconButton(
                  iconSize: 40.0,
                  icon: const Icon(Icons.skip_previous),
                  onPressed: () {
                    setState(() {
                      final position = _player.position;
                      if (position.inSeconds <= 2 && _currentSongIndex > 0) {
                        _player.seekToPrevious();
                      } else {
                        _player.seek(Duration.zero);
                      }
                    });
                  },
                ),
                IconButton(
                  iconSize: 48.0,
                  icon: Icon(_player.playing ? Icons.pause : Icons.play_arrow),
                  onPressed: _playPause,
                ),
                IconButton(
                  iconSize: 40.0,
                  icon: const Icon(Icons.skip_next),
                  onPressed: () {
                    if (_currentSongIndex < _songs.length - 1) {
                      _player.seekToNext();
                    }
                  },
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMiniPlayer() {
    final song = _songs.isNotEmpty ? _songs[_currentSongIndex] : null;
    final audioSource = song != null ? song['audioSource'] as ProgressiveAudioSource : null;

    return Material(
      elevation: 6,
      color: Colors.white,
      child: InkWell(
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
              if (_selectedAlbum?['imageUrl']?.isNotEmpty == true)
                ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: Image.network(
                    _selectedAlbum!['imageUrl']!,
                    width: 50,
                    height: 50,
                    fit: BoxFit.cover,
                  ),
                ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  audioSource?.tag.title ?? 'Playing...',
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 16),
                ),
              ),
              StreamBuilder<PlayerState>(
                stream: _player.playerStateStream,
                builder: (context, snapshot) {
                  final playerState = snapshot.data;
                  return IconButton(
                    icon: Icon(playerState?.playing == true ? Icons.pause : Icons.play_arrow),
                    onPressed: () async {
                      if (_songs.isEmpty || _selectedAlbum == null) return;
                      if (_player.playerState.playing) {
                        await _player.pause();
                      } else {
                        await _player.play();
                      }
                      setState(() {});
                    },
                  );
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: _isPlayerExpanded ? null : AppBar(title: const Text('KHInsider Search')),
      body: Stack(
        children: [
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: Column(
              children: [
                if (_selectedAlbum == null) ...[
                  TextField(
                    controller: _searchController,
                    decoration: const InputDecoration(
                      labelText: 'Search Albums',
                      border: OutlineInputBorder(),
                    ),
                    onSubmitted: (value) {
                      setState(() {});
                    },
                  ),
                  const SizedBox(height: 16),
                ],
                Expanded(
                  child: _selectedAlbum == null ? _buildAlbumList() : _buildSongList(),
                ),
              ],
            ),
          ),
          if (_currentSongUrl != null)
            Align(
              alignment: Alignment.bottomCenter,
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 300),
                child: _isPlayerExpanded ? _buildExpandedPlayer() : _buildMiniPlayer(),
              ),
            ),
        ],
      ),
      bottomNavigationBar: _isPlayerExpanded
          ? null
          : BottomNavigationBar(
              currentIndex: 0,
              onTap: (index) {},
              items: const [
                BottomNavigationBarItem(icon: Icon(Icons.search), label: 'Search'),
                BottomNavigationBarItem(icon: Icon(Icons.favorite), label: 'Favorites'),
              ],
            ),
    );
  }
}

List<Map<String, String>> parseAlbumList(String htmlBody) {
  final document = html_parser.parse(htmlBody);
  final rows = document.querySelectorAll('table.albumList tbody tr');

  return rows
      .map((row) {
        final cols = row.querySelectorAll('td');
        if (cols.length < 5) return null;

        final albumName = '${cols[1].querySelector('a')?.text.trim() ?? ''} ${cols[1].querySelector('span')?.text.trim() ?? ''}';
        final platform = cols[2].text.trim();
        final type = cols[3].text.trim();
        final year = cols[4].text.trim();
        final imageUrl = cols[0].querySelector('img')?.attributes['src'] ?? '';
        final albumUrl = cols[1].querySelector('a')?.attributes['href'] ?? '';

        return {
          'albumName': albumName.trim(),
          'platform': platform,
          'type': type,
          'year': year,
          'imageUrl': imageUrl,
          'albumUrl': albumUrl,
        };
      })
      .whereType<Map<String, String>>()
      .toList();
}

Future<List<Map<String, dynamic>>> parseSongList(String htmlBody, String albumName, String albumImageUrl) async {
  final document = html_parser.parse(htmlBody);
  final rows = document.querySelectorAll('#songlist tr');
  final List<Map<String, dynamic>> songs = [];

  for (final row in rows) {
    final links = row.querySelectorAll('a');
    if (links.length < 2) continue;

    final name = links[0].text.trim();
    final runtime = links[1].text.trim();
    final href = links[0].attributes['href'];
    if (href == null || name.isEmpty || runtime.isEmpty) continue;

    final detailUrl = 'https://downloads.khinsider.com$href';
    try {
      final mp3Url = await _fetchActualMp3UrlStatic(detailUrl);
      final audioSource = ProgressiveAudioSource(
        Uri.parse(mp3Url),
        tag: MediaItem(
          id: mp3Url,
          title: name,
          album: albumName,
          artist: albumName,
          artUri: albumImageUrl.isNotEmpty ? Uri.parse(albumImageUrl) : null,
        ),
      );
      songs.add({
        'audioSource': audioSource,
        'runtime': runtime,
      });
    } catch (e) {
      debugPrint('Error fetching MP3 URL for $name: $e');
    }
  }

  return songs;
}

Future<String> _fetchActualMp3UrlStatic(String detailPageUrl) async {
  final client = http.Client();
  try {
    final response = await client.get(Uri.parse(detailPageUrl));
    if (response.statusCode == 200) {
      final document = html_parser.parse(response.body);
      final mp3Anchor = document.querySelectorAll('a').firstWhere(
        (a) => a.attributes['href']?.endsWith('.mp3') ?? false,
        orElse: () => throw Exception('MP3 link not found'),
      );
      return mp3Anchor.attributes['href']!;
    }
    throw Exception('Failed to load MP3 URL');
  } finally {
    client.close();
  }
}