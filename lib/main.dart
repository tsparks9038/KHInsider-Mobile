import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:html/parser.dart' as html_parser;
import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';
import 'package:just_audio_background/just_audio_background.dart';
import 'package:pool/pool.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:path_provider/path_provider.dart';
import 'package:file_picker/file_picker.dart';
import 'package:share_plus/share_plus.dart';
import 'package:app_links/app_links.dart';

class PreferencesManager {
  static const String _backupFileName = 'shared_prefs_backup.json';
  static SharedPreferences? _prefs;

  static Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();
  }

  static Future<bool> setBool(String key, bool value) async {
    final result = await _prefs!.setBool(key, value);
    await _backupPreferences();
    return result;
  }

  static Future<bool> setString(String key, String value) async {
    final result = await _prefs!.setString(key, value);
    await _backupPreferences();
    return result;
  }

  static bool? getBool(String key) => _prefs!.getBool(key);
  static String? getString(String key) => _prefs!.getString(key);

  static Future<void> _backupPreferences() async {
    try {
      final prefsMap = _prefs!.getKeys().fold<Map<String, dynamic>>({}, (
        map,
        key,
      ) {
        map[key] = _prefs!.get(key);
        return map;
      });

      final jsonString = jsonEncode(prefsMap);
      final directory = await getApplicationDocumentsDirectory();
      final file = File('${directory.path}/$_backupFileName');
      await file.writeAsString(jsonString);
      debugPrint('Preferences backed up to ${file.path}');
    } catch (e) {
      debugPrint('Error backing up preferences: $e');
    }
  }

  static Future<File> exportPreferences() async {
    final directory = await getApplicationDocumentsDirectory();
    final backupFile = File('${directory.path}/$_backupFileName');
    final exportFile = File(
      '${directory.path}/shared_prefs_export.json',
    ); // Changed to .json

    if (await backupFile.exists()) {
      await backupFile.copy(exportFile.path);
      debugPrint('Preferences exported to ${exportFile.path}');
    } else {
      await _backupPreferences();
      await backupFile.copy(exportFile.path);
    }
    return exportFile;
  }

  static Future<bool> importPreferences(File file) async {
    try {
      final jsonString = await file.readAsString();
      final prefsMap = jsonDecode(jsonString) as Map<String, dynamic>;

      await _prefs!.clear();
      for (final entry in prefsMap.entries) {
        if (entry.value is bool) {
          await _prefs!.setBool(entry.key, entry.value);
        } else if (entry.value is String) {
          await _prefs!.setString(entry.key, entry.value);
        } else if (entry.value is int) {
          await _prefs!.setInt(entry.key, entry.value);
        } else if (entry.value is double) {
          await _prefs!.setDouble(entry.key, entry.value);
        } else if (entry.value is List<String>) {
          await _prefs!.setStringList(entry.key, entry.value);
        }
      }
      await _backupPreferences();
      debugPrint('Preferences imported from ${file.path}');
      return true;
    } catch (e) {
      debugPrint('Error importing preferences: $e');
      return false;
    }
  }
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await JustAudioBackground.init(
    androidNotificationChannelId: 'com.example.khinsider_android.channel.audio',
    androidNotificationChannelName: 'Audio playback',
    androidNotificationOngoing: true,
  );
  await PreferencesManager.init();
  runApp(const SearchApp());
}

class SearchApp extends StatelessWidget {
  const SearchApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(home: const SearchScreen(), theme: ThemeData.light());
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
  final AppLinks _appLinks = AppLinks();
  String? _currentSongUrl;
  int _currentSongIndex = 0;
  bool _isPlayerExpanded = false;
  bool _isShuffleEnabled = false;
  LoopMode _loopMode = LoopMode.off;
  List<Map<String, String>> _albums = [];
  ConcatenatingAudioSource? _playlist;
  List<Map<String, dynamic>> _songs = [];
  Map<String, String>? _selectedAlbum;
  List<Map<String, dynamic>> _favorites = [];
  int _currentNavIndex = 0;
  bool _isFavoritesSelected = false;
  List<String> _albumTypes = ['All'];
  String _selectedType = 'All';
  StreamSubscription? _uriLinkSubscription;

  @override
  void initState() {
    super.initState();
    _loadPreferences();
    _initDeepLinks();
    _player.sequenceStateStream.listen((state) {
      if (state == null) return;
      final index = state.currentIndex;
      setState(() {
        _currentSongIndex = index;
        _currentSongUrl =
            _playlist != null && index < _playlist!.children.length
                ? (_playlist!.children[index] as ProgressiveAudioSource).uri
                    .toString()
                : null;
      });
    });
  }

  @override
  void dispose() {
    _uriLinkSubscription?.cancel();
    _player.dispose();
    _httpClient.close();
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _initDeepLinks() async {
    try {
      final initialUri = await _appLinks.getInitialLink();
      if (initialUri != null) {
        await _handleDeepLink(initialUri);
      }
    } catch (e) {
      debugPrint('Error getting initial URI: $e');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to process initial link: $e')),
      );
    }

    _uriLinkSubscription = _appLinks.uriLinkStream.listen(
      (Uri? uri) {
        if (uri != null) {
          _handleDeepLink(uri);
        }
      },
      onError: (e) {
        debugPrint('Error in URI stream: $e');
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Failed to process link: $e')));
      },
    );
  }

  Future<void> _handleDeepLink(Uri uri) async {
    if (uri.host != 'downloads.khinsider.com' ||
        !uri.path.startsWith('/game-soundtracks/album')) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Unsupported deep link.')));
      return;
    }

    final albumUrl = uri.path;
    final songIndex = int.tryParse(uri.queryParameters['song'] ?? '');

    setState(() {
      _selectedAlbum = {
        'albumUrl': albumUrl,
        'albumName': 'Unknown',
        'imageUrl': '',
        'type': '',
        'year': '',
        'platform': '',
      };
      _songs = [];
      _playlist = null;
      _currentSongIndex = 0;
      _currentSongUrl = null;
      _isFavoritesSelected = false;
      _isPlayerExpanded =
          songIndex != null; // Only expand player if songIndex is provided
    });

    try {
      await _fetchAlbumPage(albumUrl);
      if (songIndex != null &&
          songIndex >= 0 &&
          _songs.isNotEmpty &&
          songIndex < _songs.length) {
        await _playAudioSourceAtIndex(songIndex, false);
        setState(() {
          _isPlayerExpanded = true;
        });
      } else if (songIndex != null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Invalid song index or album not found.'),
          ),
        );
      }
      // If no songIndex, just show the album details (song list), no snackbar needed
    } catch (e) {
      debugPrint('Error handling deep link: $e');
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Failed to load album: $e')));
    }
  }

  Future<void> _loadPreferences() async {
    setState(() {
      _isShuffleEnabled = PreferencesManager.getBool('shuffleEnabled') ?? false;
      final loopModeString = PreferencesManager.getString('loopMode') ?? 'off';
      _loopMode =
          {
            'off': LoopMode.off,
            'one': LoopMode.one,
            'all': LoopMode.all,
          }[loopModeString] ??
          LoopMode.off;
    });
    _player.setShuffleModeEnabled(_isShuffleEnabled);
    _player.setLoopMode(_loopMode);
    _loadFavorites();
  }

  Future<void> _loadFavorites() async {
    final favoritesJson = PreferencesManager.getString('favorites');
    if (favoritesJson != null) {
      final List<dynamic> favoritesList = jsonDecode(favoritesJson);
      setState(() {
        _favorites =
            favoritesList.map((item) {
              final map = item as Map<String, dynamic>;
              final mediaItem = MediaItem(
                id: map['id'],
                title: map['title'],
                album: map['album'],
                artist: map['artist'],
                artUri: map['artUri'] != null ? Uri.parse(map['artUri']) : null,
              );
              return {
                'audioSource': ProgressiveAudioSource(
                  Uri.parse(map['id']),
                  tag: mediaItem,
                ),
                'runtime': map['runtime'],
                'albumUrl': map['albumUrl'],
                'index': map['index'],
              };
            }).toList();
      });
    }
  }

  Future<void> _savePreferences() async {
    await PreferencesManager.setBool('shuffleEnabled', _isShuffleEnabled);
    await PreferencesManager.setString(
      'loopMode',
      {
        LoopMode.off: 'off',
        LoopMode.one: 'one',
        LoopMode.all: 'all',
      }[_loopMode]!,
    );
  }

  Future<void> _saveFavorites() async {
    final favoritesJson = jsonEncode(
      _favorites.map((song) {
        final mediaItem =
            (song['audioSource'] as ProgressiveAudioSource).tag as MediaItem;
        return {
          'id': mediaItem.id,
          'title': mediaItem.title,
          'album': mediaItem.album,
          'artist': mediaItem.artist,
          'artUri': mediaItem.artUri?.toString(),
          'runtime': song['runtime'],
          'albumUrl': song['albumUrl'],
          'index': song['index'],
        };
      }).toList(),
    );
    await PreferencesManager.setString('favorites', favoritesJson);
  }

  Future<List<Map<String, String>>> _fetchAlbumsAsync(String query) async {
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

  void _playPause() {
    setState(() {
      if (_player.playing) {
        _player.pause();
      } else {
        _player.play();
      }
    });
  }

  Future<void> _playAudioSourceAtIndex(int index, bool isFavorites) async {
    try {
      if (_playlist == null || index >= _playlist!.children.length) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Cannot play song: invalid playlist or index.'),
          ),
        );
        return;
      }
      await _player.setAudioSource(_playlist!, initialIndex: index);
      _player.play();
      setState(() {
        _currentSongIndex = index;
        _currentSongUrl =
            (_playlist!.children[index] as ProgressiveAudioSource).uri
                .toString();
        _isFavoritesSelected = isFavorites;
      });
    } catch (e) {
      debugPrint('Error playing audio: $e');
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Failed to play song: $e')));
    }
  }

  void _toggleShuffle() async {
    if (_playlist == null) return;
    setState(() {
      _isShuffleEnabled = !_isShuffleEnabled;
    });
    await _player.setShuffleModeEnabled(_isShuffleEnabled);
    if (_isShuffleEnabled) {
      await _player.shuffle();
    }
    await _savePreferences();
  }

  void _toggleLoopMode() {
    setState(() {
      if (_loopMode == LoopMode.off) {
        _loopMode = LoopMode.one;
      } else if (_loopMode == LoopMode.one) {
        _loopMode = LoopMode.all;
      } else {
        _loopMode = LoopMode.off;
      }
    });
    _player.setLoopMode(_loopMode);
    _savePreferences();
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

        final albumName = _selectedAlbum?['albumName'] ?? 'Unknown';
        final type = _selectedAlbum?['type'] ?? '';
        final year = _selectedAlbum?['year'] ?? '';
        final platform = _selectedAlbum?['platform'] ?? '';

        setState(() {
          _selectedAlbum = {
            'imageUrl': imageUrl,
            'albumName': albumName,
            'albumUrl': albumUrl,
            'type': type,
            'year': year,
            'platform': platform,
          };
        });

        final songs = await compute(
          (input) => parseSongList(
            input['body']!,
            input['albumName']!,
            input['imageUrl']!,
            input['albumUrl']!,
          ),
          {
            'body': response.body,
            'albumName': albumName,
            'imageUrl': imageUrl,
            'albumUrl': albumUrl,
          },
        );

        setState(() {
          _songs = songs;
          _playlist = ConcatenatingAudioSource(
            children:
                songs
                    .map((song) => song['audioSource'] as AudioSource)
                    .toList(),
          );
          _player.setShuffleModeEnabled(_isShuffleEnabled);
          if (_isShuffleEnabled) {
            _player.shuffle();
          }
          _player.setLoopMode(_loopMode);
          _isFavoritesSelected = false;
        });
      } else {
        debugPrint('Error: ${response.statusCode}');
        throw Exception('Failed to load album page: ${response.statusCode}');
      }
    } catch (e) {
      debugPrint('Error occurred while fetching album page: $e');
      throw e; // Rethrow to be caught in _handleDeepLink
    }
  }

  String _getHighResImageUrl(String url) {
    return url.replaceFirst('/thumbs/', '/');
  }

  void _toggleFavorite(Map<String, dynamic> song) {
    setState(() {
      final mediaItem =
          (song['audioSource'] as ProgressiveAudioSource).tag as MediaItem;
      if (_favorites.any(
        (fav) =>
            (fav['audioSource'] as ProgressiveAudioSource).tag.id ==
            mediaItem.id,
      )) {
        _favorites.removeWhere(
          (fav) =>
              (fav['audioSource'] as ProgressiveAudioSource).tag.id ==
              mediaItem.id,
        );
      } else {
        _favorites.add(song);
      }
    });
    _saveFavorites();
  }

  bool _isFavorited(MediaItem mediaItem) {
    return _favorites.any(
      (fav) =>
          (fav['audioSource'] as ProgressiveAudioSource).tag.id == mediaItem.id,
    );
  }

  void _shareAlbum(String albumUrl) {
    final shareUrl = 'https://downloads.khinsider.com$albumUrl';
    Share.share(shareUrl, subject: 'Check out this album!');
  }

  void _shareSong(Map<String, dynamic> song) {
    final albumUrl = song['albumUrl'] as String;
    final index = song['index'] as int;
    final albumIndex = index - 1;
    final shareUrl =
        'https://downloads.khinsider.com$albumUrl?song=$albumIndex';
    Share.share(shareUrl, subject: 'Check out this song!');
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
          final types =
              _albums
                  .map(
                    (album) => album['type']!.isEmpty ? 'None' : album['type']!,
                  )
                  .toSet()
                  .toList()
                ..sort();
          _albumTypes = ['All', ...types];

          final filteredAlbums =
              _selectedType == 'All'
                  ? _albums
                  : _albums
                      .where(
                        (album) =>
                            (album['type']!.isEmpty
                                ? 'None'
                                : album['type']!) ==
                            _selectedType,
                      )
                      .toList();

          return Column(
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8.0),
                child: DropdownButton<String>(
                  value: _selectedType,
                  isExpanded: true,
                  hint: const Text('Filter by Type'),
                  items:
                      _albumTypes.map((type) {
                        return DropdownMenuItem<String>(
                          value: type,
                          child: Text(type),
                        );
                      }).toList(),
                  onChanged: (value) {
                    setState(() {
                      _selectedType = value ?? 'All';
                    });
                  },
                ),
              ),
              const SizedBox(height: 8),
              Expanded(
                child: ListView.builder(
                  itemCount: filteredAlbums.length,
                  itemBuilder: (context, index) {
                    final album = filteredAlbums[index];
                    return ListTile(
                      leading:
                          album['imageUrl']!.isNotEmpty
                              ? CircleAvatar(
                                backgroundImage: NetworkImage(
                                  album['imageUrl']!,
                                ),
                                radius: 30,
                              )
                              : const CircleAvatar(
                                backgroundColor: Colors.grey,
                                radius: 30,
                                child: Icon(
                                  Icons.music_note,
                                  color: Colors.white,
                                ),
                              ),
                      title: Text(album['albumName']!),
                      subtitle: Text(
                        '${album['type']!.isEmpty ? 'None' : album['type']} - ${album['year']} | ${album['platform']}',
                      ),
                      onTap: () {
                        setState(() {
                          _selectedAlbum = album;
                          _songs = [];
                          _playlist = null;
                          _currentSongIndex = 0;
                          _currentSongUrl = null;
                          _isFavoritesSelected = false;
                        });
                        _fetchAlbumPage(album['albumUrl']!);
                      },
                    );
                  },
                ),
              ),
            ],
          );
        }
      },
    );
  }

  Widget _buildSongList() {
    if (_selectedAlbum == null) {
      return const Center(child: Text('No album selected.'));
    }
    return ListView(
      children: [
        const SizedBox(height: 16),
        Center(
          child:
              _selectedAlbum!['imageUrl']?.isNotEmpty == true
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
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              _selectedAlbum!['albumName'] ?? 'Unknown',
              style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
            ),
            IconButton(
              icon: const Icon(Icons.share),
              onPressed: () => _shareAlbum(_selectedAlbum!['albumUrl']!),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          '${_selectedAlbum!['type']?.isEmpty == true ? 'None' : _selectedAlbum!['type']} - ${_selectedAlbum!['year']} | ${_selectedAlbum!['platform']}',
          style: const TextStyle(color: Colors.grey),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 24),
        ..._songs.asMap().entries.map((entry) {
          final index = entry.key;
          final song = entry.value;
          final audioSource = song['audioSource'] as ProgressiveAudioSource;
          final mediaItem = audioSource.tag as MediaItem;
          return ListTile(
            title: Text(audioSource.tag.title ?? 'Unknown'),
            subtitle: Text(song['runtime'] ?? 'Unknown'),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  icon: Icon(
                    _isFavorited(mediaItem)
                        ? Icons.favorite
                        : Icons.favorite_border,
                    color: _isFavorited(mediaItem) ? Colors.red : null,
                  ),
                  onPressed: () => _toggleFavorite(song),
                ),
                IconButton(
                  icon: const Icon(Icons.share),
                  onPressed: () => _shareSong(song),
                ),
              ],
            ),
            onTap: () {
              setState(() {
                _isPlayerExpanded = false;
              });
              _playAudioSourceAtIndex(index, false);
            },
          );
        }),
        if (_currentSongUrl != null) const SizedBox(height: 70),
      ],
    );
  }

  Widget _buildFavoritesList() {
    if (_favorites.isEmpty) {
      return const Center(child: Text('No favorite songs yet.'));
    }

    _playlist = ConcatenatingAudioSource(
      children:
          _favorites.map((song) => song['audioSource'] as AudioSource).toList(),
    );

    return ListView(
      children: [
        const SizedBox(height: 16),
        Center(
          child: Container(
            width: 200,
            height: 200,
            color: Colors.grey[300],
            child: const Icon(Icons.favorite, size: 100, color: Colors.red),
          ),
        ),
        const SizedBox(height: 12),
        const Text(
          'Favorites',
          style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 24),
        ..._favorites.asMap().entries.map((entry) {
          final index = entry.key;
          final song = entry.value;
          final audioSource = song['audioSource'] as ProgressiveAudioSource;
          final mediaItem = audioSource.tag as MediaItem;
          return ListTile(
            leading:
                mediaItem.artUri != null
                    ? CircleAvatar(
                      backgroundImage: NetworkImage(
                        mediaItem.artUri.toString(),
                      ),
                      radius: 30,
                    )
                    : const CircleAvatar(
                      backgroundColor: Colors.grey,
                      radius: 30,
                      child: Icon(Icons.music_note, color: Colors.white),
                    ),
            title: Text(mediaItem.title ?? 'Unknown'),
            subtitle: Text(song['runtime'] ?? 'Unknown'),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  icon: Icon(
                    _isFavorited(mediaItem)
                        ? Icons.favorite
                        : Icons.favorite_border,
                    color: _isFavorited(mediaItem) ? Colors.red : null,
                  ),
                  onPressed: () => _toggleFavorite(song),
                ),
                IconButton(
                  icon: const Icon(Icons.share),
                  onPressed: () => _shareSong(song),
                ),
              ],
            ),
            onTap: () {
              setState(() {
                _isPlayerExpanded = false;
              });
              _playAudioSourceAtIndex(index, true);
            },
          );
        }),
        if (_currentSongUrl != null) const SizedBox(height: 70),
      ],
    );
  }

  Widget _buildExpandedPlayer() {
    final songList = _isFavoritesSelected ? _favorites : _songs;
    if (songList.isEmpty || _currentSongIndex >= songList.length) {
      return const SizedBox();
    }
    final song = songList[_currentSongIndex];
    final audioSource = song['audioSource'] as ProgressiveAudioSource;
    final mediaItem = audioSource.tag as MediaItem;

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
            if (mediaItem.artUri != null)
              ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: Image.network(
                  mediaItem.artUri.toString(),
                  width: 200,
                  height: 200,
                  fit: BoxFit.cover,
                ),
              )
            else
              Container(
                width: 200,
                height: 200,
                color: Colors.grey[300],
                child: const Icon(Icons.music_note, size: 100),
              ),
            const SizedBox(height: 20),
            Text(
              mediaItem.title ?? 'Unknown',
              style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
              textAlign: TextAlign.center,
            ),
            Text(
              mediaItem.album ?? 'Unknown',
              style: const TextStyle(fontSize: 16, color: Colors.grey),
              textAlign: TextAlign.center,
            ),
            IconButton(
              icon: Icon(
                _isFavorited(mediaItem)
                    ? Icons.favorite
                    : Icons.favorite_border,
                color: _isFavorited(mediaItem) ? Colors.red : null,
              ),
              onPressed: () => _toggleFavorite(song),
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
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                IconButton(
                  iconSize: 40.0,
                  icon: Icon(
                    Icons.shuffle,
                    color: _isShuffleEnabled ? Colors.blue : Colors.grey,
                  ),
                  onPressed: _toggleShuffle,
                ),
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
                    if (_currentSongIndex < songList.length - 1) {
                      _player.seekToNext();
                    }
                  },
                ),
                IconButton(
                  iconSize: 40.0,
                  icon: Icon(
                    _loopMode == LoopMode.one ? Icons.repeat_one : Icons.repeat,
                    color:
                        _loopMode != LoopMode.off ? Colors.blue : Colors.grey,
                  ),
                  onPressed: _toggleLoopMode,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMiniPlayer() {
    final songList = _isFavoritesSelected ? _favorites : _songs;
    if (songList.isEmpty || _currentSongIndex >= songList.length) {
      return const SizedBox();
    }
    final song = songList[_currentSongIndex];
    final audioSource = song['audioSource'] as ProgressiveAudioSource;
    final mediaItem = audioSource.tag as MediaItem;

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
              if (mediaItem.artUri != null)
                ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: Image.network(
                    mediaItem.artUri.toString(),
                    width: 50,
                    height: 50,
                    fit: BoxFit.cover,
                  ),
                )
              else
                Container(
                  width: 50,
                  height: 50,
                  color: Colors.grey[300],
                  child: const Icon(Icons.music_note, size: 30),
                ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  mediaItem.title ?? 'Playing...',
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 16),
                ),
              ),
              IconButton(
                icon: Icon(
                  _isFavorited(mediaItem)
                      ? Icons.favorite
                      : Icons.favorite_border,
                  color: _isFavorited(mediaItem) ? Colors.red : null,
                ),
                onPressed: () => _toggleFavorite(song),
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
                      if (songList.isEmpty) return;
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
                if (_currentNavIndex == 0 && _selectedAlbum == null) ...[
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
                  child:
                      _currentNavIndex == 0
                          ? (_selectedAlbum == null
                              ? _buildAlbumList()
                              : _buildSongList())
                          : _buildFavoritesList(),
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
              ? null
              : BottomNavigationBar(
                currentIndex: _currentNavIndex,
                onTap: (index) {
                  setState(() {
                    _currentNavIndex = index;
                    if (index == 0) {
                      _selectedAlbum = null;
                      _songs = [];
                      _playlist = null;
                      _currentSongIndex = 0;
                      _currentSongUrl = null;
                      _isFavoritesSelected = false;
                    } else if (index == 1) {
                      _selectedAlbum = null;
                      _songs = [];
                      _isFavoritesSelected = true;
                      if (_favorites.isNotEmpty) {
                        _playlist = ConcatenatingAudioSource(
                          children:
                              _favorites
                                  .map(
                                    (song) =>
                                        song['audioSource'] as AudioSource,
                                  )
                                  .toList(),
                        );
                      }
                    } else if (index == 2) {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (context) => const SettingsScreen(),
                        ),
                      ).then((_) {
                        setState(() {
                          _currentNavIndex = 0;
                        });
                      });
                    }
                  });
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
                  BottomNavigationBarItem(
                    icon: Icon(Icons.settings),
                    label: 'Settings',
                  ),
                ],
              ),
    );
  }
}

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          children: [
            ElevatedButton(
              onPressed: () async {
                try {
                  final file = await PreferencesManager.exportPreferences();
                  await Share.shareXFiles([
                    XFile(file.path),
                  ], text: 'Exported preferences from KHInsider Search');
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text(
                        'Preferences exported and shared from ${file.path}',
                      ),
                    ),
                  );
                } catch (e) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('Error exporting preferences: $e')),
                  );
                }
              },
              child: const Text('Export Preferences'),
            ),
            const SizedBox(height: 16),
            ElevatedButton(
              onPressed: () async {
                final result = await FilePicker.platform.pickFiles(
                  type: FileType.custom,
                  allowedExtensions: ['json'],
                );
                if (result != null && result.files.single.path != null) {
                  final file = File(result.files.single.path!);
                  final success = await PreferencesManager.importPreferences(
                    file,
                  );
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text(
                        success
                            ? 'Preferences imported successfully'
                            : 'Failed to import preferences',
                      ),
                    ),
                  );
                  Navigator.pushReplacement(
                    context,
                    MaterialPageRoute(builder: (context) => const SearchApp()),
                  );
                }
              },
              child: const Text('Import Preferences'),
            ),
          ],
        ),
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

        final albumName =
            '${cols[1].querySelector('a')?.text.trim() ?? ''} ${cols[1].querySelector('span')?.text.trim() ?? ''}';
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

Future<List<Map<String, dynamic>>> parseSongList(
  String htmlBody,
  String albumName,
  String albumImageUrl,
  String albumUrl,
) async {
  final document = html_parser.parse(htmlBody);
  final rows = document.querySelectorAll('#songlist tr');
  final List<Map<String, dynamic>> songs = [];
  final List<Future<Map<String, dynamic>?>> futures = [];
  final pool = Pool(Platform.numberOfProcessors);

  for (var i = 0; i < rows.length; i++) {
    final row = rows[i];
    final links = row.querySelectorAll('a');
    if (links.length < 2) continue;

    final name = links[0].text.trim();
    final runtime = links[1].text.trim();
    final href = links[0].attributes['href'];
    if (href == null || name.isEmpty || runtime.isEmpty) continue;

    final detailUrl = 'https://downloads.khinsider.com$href';

    futures.add(
      pool.withResource(
        () => _fetchActualMp3UrlStatic(detailUrl)
            .then((mp3Url) {
              final audioSource = ProgressiveAudioSource(
                Uri.parse(mp3Url),
                tag: MediaItem(
                  id: mp3Url,
                  title: name,
                  album: albumName,
                  artist: albumName,
                  artUri:
                      albumImageUrl.isNotEmpty
                          ? Uri.parse(albumImageUrl)
                          : null,
                ),
              );
              return {
                'audioSource': audioSource,
                'runtime': runtime,
                'albumUrl': albumUrl,
                'index': i,
              };
            })
            .catchError((e) {
              debugPrint('Error fetching MP3 URL for $name: $e');
              return null;
            }),
      ),
    );
  }

  final results = await Future.wait(futures);
  songs.addAll(results.whereType<Map<String, dynamic>>());

  return songs;
}

Future<String> _fetchActualMp3UrlStatic(String detailPageUrl) async {
  final client = http.Client();
  try {
    final response = await client.get(Uri.parse(detailPageUrl));
    if (response.statusCode == 200) {
      final document = html_parser.parse(response.body);
      final mp3Anchor = document
          .querySelectorAll('a')
          .firstWhere(
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
