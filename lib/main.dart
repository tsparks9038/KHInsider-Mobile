import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:html/parser.dart' as html_parser;
import 'package:flutter/foundation.dart'; // for compute()
import 'package:just_audio/just_audio.dart';

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

  AudioPlayer _player = AudioPlayer();
  String? _currentSongUrl;
  int _currentSongIndex = 0; // Index of the currently playing song

  bool _isPlayerExpanded = false;

  @override
  void initState() {
    super.initState();
    _player = AudioPlayer();
    _player.setLoopMode(LoopMode.off);

    // Set up the listener for when a song completes
    _player.playerStateStream.listen((state) {
      if (state.processingState == ProcessingState.completed) {
        _playNextSong();
      }
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

  void _playNextSong() {
    setState(() {
      if (_currentSongIndex < _songs.length - 1) {
        _currentSongIndex++;
        _fetchActualMp3Url(_songs[_currentSongIndex].audioUrl);
      }
    });
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

        final mp3Link = mp3Anchor.attributes['href']!;
        await _player.setUrl(mp3Link); // Play the audio from the fetched URL
        _player.play(); // Start playback
      } else {
        throw Exception('Failed to load MP3 URL');
      }
    } catch (e) {
      debugPrint('Error: $e');
    }
  }

  // Format a Duration object into a readable string (e.g., "mm:ss")
  String _formatDuration(Duration duration) {
    final minutes = duration.inMinutes;
    final seconds = duration.inSeconds % 60;
    return '${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
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
                _currentSongUrl = song.audioUrl; // Set the current song URL
                _isPlayerExpanded =
                    false; // Ensure the mini player is shown after selection
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
          bottom: 40, // Adjusted padding to ensure space for controls
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
            const Spacer(), // Push image + song name into the vertical center
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
            const Spacer(), // Push the rest (slider + controls) up a bit
            // Slider and Duration display
            StreamBuilder<Duration>(
              stream: _player.positionStream,
              builder: (context, snapshot) {
                final position = snapshot.data ?? Duration.zero;
                final duration = _player.duration ?? Duration.zero;

                return Column(
                  children: [
                    Slider(
                      value: position.inSeconds.toDouble().clamp(
                        0.0,
                        duration.inSeconds.toDouble(),
                      ),
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
            const SizedBox(
              height: 8,
            ), // Reduced space before controls for better alignment
            // Controls at the bottom
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                IconButton(
                  iconSize: 40.0,
                  icon: const Icon(Icons.skip_previous),
                  onPressed: () {
                    setState(() {
                      final position = _player.position;
                      if (position.inSeconds <= 2) {
                        // Go to the previous song if the current song has been playing for 2 seconds or less
                        if (_currentSongIndex > 0) {
                          _currentSongIndex--;
                          _fetchActualMp3Url(
                            _songs[_currentSongIndex].audioUrl,
                          );
                        }
                      } else {
                        // Restart the current song
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
                  onPressed: _playNextSong,
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

    return Material(
      elevation: 6,
      color: Colors.white,
      child: InkWell(
        onTap: () {
          setState(() {
            _isPlayerExpanded = true; // Expand player when tapped
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
              StreamBuilder<PlayerState>(
                stream: _player.playerStateStream,
                builder: (context, snapshot) {
                  final playerState = snapshot.data;

                  return IconButton(
                    icon: Icon(
                      playerState?.playing == true
                          ? Icons.pause
                          : Icons.play_arrow,
                    ),
                    onPressed: () async {
                      if (_songs.isEmpty || _selectedAlbum == null) return;

                      if (_player.playerState.playing) {
                        await _player.pause();
                      } else {
                        await _player.play();
                      }

                      setState(() {}); // Trigger UI update
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
  final List<Song> songs;
  final int currentIndex;
  final void Function(int newIndex) onChangeSong;

  const PlayerWidget({
    required this.player,
    required this.songs,
    required this.currentIndex,
    required this.onChangeSong,
    super.key,
  });

  @override
  State<StatefulWidget> createState() => _PlayerWidgetState();
}

class _PlayerWidgetState extends State<PlayerWidget> {
  late AudioPlayer _player;
  late StreamSubscription _playerStateSubscription;

  bool get _isPlaying => _player.playing;

  @override
  void initState() {
    super.initState();
    _player = widget.player;
    _playerStateSubscription = _player.playerStateStream.listen((state) {
      setState(() {});
    });
  }

  @override
  void dispose() {
    _playerStateSubscription.cancel();
    super.dispose();
  }

  void _playPause() {
    if (_isPlaying) {
      _player.pause();
    } else {
      _player.play();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              onPressed: () {
                if (widget.currentIndex > 0) {
                  widget.onChangeSong(widget.currentIndex - 1);
                }
              },
              iconSize: 40.0,
              icon: const Icon(Icons.skip_previous),
            ),
            IconButton(
              onPressed: _playPause,
              iconSize: 48.0,
              icon: Icon(_isPlaying ? Icons.pause : Icons.play_arrow),
            ),
            IconButton(
              onPressed: () {
                _player.stop();
              },
              iconSize: 48.0,
              icon: const Icon(Icons.stop),
            ),
            IconButton(
              onPressed: () {
                if (widget.currentIndex < widget.songs.length - 1) {
                  widget.onChangeSong(widget.currentIndex + 1);
                }
              },
              iconSize: 40.0,
              icon: const Icon(Icons.skip_next),
            ),
          ],
        ),
      ],
    );
  }
}
