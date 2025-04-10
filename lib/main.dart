import 'dart:async';
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:html/parser.dart' as html_parser;
import 'package:flutter/foundation.dart'; // for compute()

void main() => runApp(const SearchApp());

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

  List<Album> _albums = [];
  Album? _selectedAlbum;
  List<Song> _songs = [];

  final AudioPlayer _player = AudioPlayer();
  String? _currentSongUrl;
  int _currentSongIndex = 0; // Index of the currently playing song

  bool _isPlayerExpanded = false;

  @override
  void initState() {
    super.initState();
    _player.setReleaseMode(ReleaseMode.stop);

    // Set up the listener for when a song completes
    _player.onPlayerComplete.listen((_) {
      _playNextSong();
    });
  }

  // Offload network request and album list parsing to a background isolate
  Future<List<Album>> _fetchAlbumsAsync(String query) async {
    final formattedText = query.replaceAll(' ', '+');
    final url = Uri.parse(
      'https://downloads.khinsider.com/search?search=$formattedText',
    );
    final response = await _httpClient.get(url);
    if (response.statusCode == 200) {
      return await compute(parseAlbumList, response.body);
    } else {
      throw Exception('Failed to load albums');
    }
  }

  // Method to play the next song in the list
  void _playNextSong() {
    if (_currentSongIndex < _songs.length - 1) {
      _currentSongIndex++;
      _fetchActualMp3Url(_songs[_currentSongIndex].audioUrl);
    } else {
      // Reset the index or handle the end of the playlist as needed
      debugPrint('End of playlist reached.');
    }
  }

  // Updated method to fetch and play a song by its URL
  Future<void> _fetchActualMp3Url(String detailPageUrl) async {
    try {
      final response = await _httpClient.get(Uri.parse(detailPageUrl));
      if (response.statusCode == 200) {
        final document = html_parser.parse(response.body);
        final mp3Anchor = document
            .querySelectorAll('a')
            .firstWhere(
              (a) => a.attributes['href']?.endsWith('.mp3') ?? false,
              orElse: () => throw Exception('MP3 link not found'),
            );

        final mp3Link = mp3Anchor.attributes['href'];

        if (mp3Link != null) {
          final fullMp3Link =
              mp3Link.startsWith('http')
                  ? mp3Link
                  : 'https://downloads.khinsider.com$mp3Link';

          debugPrint('Playing MP3: $fullMp3Link');
          await _player.setSource(UrlSource(fullMp3Link));
          await _player.resume();
          setState(() {
            _currentSongUrl = fullMp3Link;
          });
        }
      }
    } catch (e) {
      debugPrint('Error fetching MP3 URL: $e');
    }
  }

  // Ensure that when a song is selected from the list, the correct index is set
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

  // Widget for displaying the album list
  Widget _buildAlbumList() {
    return FutureBuilder<List<Album>>(
      future: _fetchAlbumsAsync(
        _searchController.text,
      ), // Trigger the async function when the search is submitted
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

  // Widget for displaying the song list
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
              setState(() {
                _currentSongIndex = index;
              });
              _fetchActualMp3Url(song.audioUrl);
            },
          );
        }),
      ],
    );
  }

  Widget _buildExpandedPlayer() {
    final song = _songs[_currentSongIndex];

    return Material(
      elevation: 12,
      color: Colors.white,
      child: Container(
        height: MediaQuery.of(context).size.height,
        width: MediaQuery.of(context).size.width,
        color: Colors.white,
        padding: const EdgeInsets.only(
          top: 40,
          left: 20,
          right: 20,
          bottom: 20,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
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
            if (_selectedAlbum?.imageUrl.isNotEmpty == true)
              ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: Image.network(
                  _selectedAlbum!.imageUrl,
                  width: 200,
                  height: 200,
                  fit: BoxFit.cover,
                ),
              ),
            const SizedBox(height: 20),
            Text(
              song.songName,
              style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            PlayerWidget(player: _player),
          ],
        ),
      ),
    );
  }

  Widget _buildMiniPlayer() {
    final song = _songs.isNotEmpty ? _songs[_currentSongIndex] : null;

    return Material(
      elevation: 6,
      color: Colors.white,
      child: InkWell(
        onTap: () {
          if (_songs.isEmpty || _selectedAlbum == null) return;

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
              IconButton(
                icon: Icon(
                  _player.state == PlayerState.playing
                      ? Icons.pause
                      : Icons.play_arrow,
                ),
                onPressed: () async {
                  if (_songs.isEmpty || _selectedAlbum == null) return;

                  if (_player.state == PlayerState.playing) {
                    await _player.pause();
                  } else {
                    await _player.resume();
                  }

                  setState(() {});
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
      appBar:
          _isPlayerExpanded
              ? null
              : AppBar(title: const Text('KHInsider Search')),
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
                    }, // Trigger search on Enter
                  ),
                  const SizedBox(height: 16),
                ],
                Expanded(
                  child:
                      _selectedAlbum == null
                          ? _buildAlbumList()
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
                child:
                    _isPlayerExpanded
                        ? _buildExpandedPlayer()
                        : _buildMiniPlayer(),
              ),
            ),
        ],
      ),
      bottomNavigationBar:
          _isPlayerExpanded
              ? null // Hides the bottom navigation bar when player is expanded
              : BottomNavigationBar(
                currentIndex: 0,
                onTap: (index) {
                  // Handle tab switching if needed
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
}

// ========== Parsing Functions for compute() ==========

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

  return rows
      .map((row) {
        final links = row.querySelectorAll('a');
        if (links.length < 2) return null;

        final name = links[0].text.trim();
        final runtime = links[1].text.trim();
        final href = links[0].attributes['href'];

        if (href != null && name.isNotEmpty && runtime.isNotEmpty) {
          return Song(name, runtime, 'https://downloads.khinsider.com$href');
        }
        return null;
      })
      .whereType<Song>()
      .toList();
}

// ========== Models ==========

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

// ========== Player Widget ==========

class PlayerWidget extends StatefulWidget {
  final AudioPlayer player;

  const PlayerWidget({required this.player, super.key});

  @override
  State<StatefulWidget> createState() => _PlayerWidgetState();
}

class _PlayerWidgetState extends State<PlayerWidget> {
  PlayerState? _playerState;
  Duration? _duration;
  Duration? _position;

  StreamSubscription? _durationSubscription;
  StreamSubscription? _positionSubscription;
  StreamSubscription? _playerCompleteSubscription;
  StreamSubscription? _playerStateChangeSubscription;

  bool get _isPlaying => _playerState == PlayerState.playing;
  bool get _isPaused => _playerState == PlayerState.paused;
  String get _durationText => _duration?.toString().split('.').first ?? '';
  String get _positionText => _position?.toString().split('.').first ?? '';
  AudioPlayer get player => widget.player;

  @override
  void initState() {
    super.initState();
    _playerState = player.state;
    player.getDuration().then((value) => setState(() => _duration = value));
    player.getCurrentPosition().then(
      (value) => setState(() => _position = value),
    );
    _initStreams();
  }

  @override
  void setState(VoidCallback fn) {
    if (mounted) super.setState(fn);
  }

  @override
  void dispose() {
    _durationSubscription?.cancel();
    _positionSubscription?.cancel();
    _playerCompleteSubscription?.cancel();
    _playerStateChangeSubscription?.cancel();
    super.dispose();
  }

  void _initStreams() {
    _durationSubscription = player.onDurationChanged.listen(
      (d) => setState(() => _duration = d),
    );
    _positionSubscription = player.onPositionChanged.listen(
      (p) => setState(() => _position = p),
    );
    _playerCompleteSubscription = player.onPlayerComplete.listen((_) {
      setState(() {
        _playerState = PlayerState.stopped;
        _position = Duration.zero;
      });
    });
    _playerStateChangeSubscription = player.onPlayerStateChanged.listen((
      state,
    ) {
      setState(() => _playerState = state);
    });
  }

  Future<void> _play() async {
    await player.resume();
  }

  Future<void> _pause() async {
    await player.pause();
  }

  Future<void> _stop() async {
    await player.stop();
    setState(() {
      _playerState = PlayerState.stopped;
      _position = Duration.zero;
    });
  }

  void _rewind() {
    if (_position != null && _position! > const Duration(seconds: 3)) {
      player.seek(Duration.zero);
    } else {
      final parent = context.findAncestorStateOfType<_SearchScreenState>();
      if (parent != null && parent._currentSongIndex > 0) {
        parent.setState(() {
          parent._currentSongIndex--;
        });
        parent._fetchActualMp3Url(
          parent._songs[parent._currentSongIndex].audioUrl,
        );
      }
    }
  }

  void _skip() {
    final parent = context.findAncestorStateOfType<_SearchScreenState>();
    if (parent != null && parent._currentSongIndex < parent._songs.length - 1) {
      parent.setState(() {
        parent._currentSongIndex++;
      });
      parent._fetchActualMp3Url(
        parent._songs[parent._currentSongIndex].audioUrl,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).primaryColor;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              onPressed: _rewind,
              iconSize: 40.0,
              icon: const Icon(Icons.skip_previous),
              color: color,
            ),
            IconButton(
              onPressed: _isPlaying ? null : _play,
              iconSize: 48.0,
              icon: const Icon(Icons.play_arrow),
              color: color,
            ),
            IconButton(
              onPressed: _isPlaying ? _pause : null,
              iconSize: 48.0,
              icon: const Icon(Icons.pause),
              color: color,
            ),
            IconButton(
              onPressed: _isPlaying || _isPaused ? _stop : null,
              iconSize: 48.0,
              icon: const Icon(Icons.stop),
              color: color,
            ),
            IconButton(
              onPressed: _skip,
              iconSize: 40.0,
              icon: const Icon(Icons.skip_next),
              color: color,
            ),
          ],
        ),
        Slider(
          onChanged: (value) {
            final duration = _duration;
            if (duration == null) return;
            final position = value * duration.inMilliseconds;
            player.seek(Duration(milliseconds: position.round()));
          },
          value:
              (_position != null &&
                      _duration != null &&
                      _position!.inMilliseconds > 0 &&
                      _position!.inMilliseconds < _duration!.inMilliseconds)
                  ? _position!.inMilliseconds / _duration!.inMilliseconds
                  : 0.0,
        ),
        Text(
          _position != null
              ? '$_positionText / $_durationText'
              : _duration != null
              ? _durationText
              : '',
          style: const TextStyle(fontSize: 16.0),
        ),
      ],
    );
  }
}
