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
import 'package:url_launcher/url_launcher.dart';
import 'package:cookie_jar/cookie_jar.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';
import 'package:webview_flutter/webview_flutter.dart';

class WebViewScreen extends StatefulWidget {
  final String url;
  final VoidCallback onLoginSuccess;

  const WebViewScreen({
    super.key,
    required this.url,
    required this.onLoginSuccess,
  });

  @override
  State<WebViewScreen> createState() => _WebViewScreenState();
}

class _WebViewScreenState extends State<WebViewScreen> {
  late final WebViewController _controller;
  final WebViewCookieManager _cookieManager = WebViewCookieManager();
  bool _loginAttempted = false;

  @override
  void initState() {
    super.initState();
    _controller =
        WebViewController()
          ..setJavaScriptMode(JavaScriptMode.unrestricted)
          ..setNavigationDelegate(
            NavigationDelegate(
              onPageFinished: (String url) async {
                // Only check after we've seen a login attempt
                if (_loginAttempted &&
                    (url.contains('/forums/index.php') ||
                        url.contains('/account/') ||
                        url.contains('/members/'))) {
                  await _verifyLoginSuccess();
                }
              },
              onNavigationRequest: (NavigationRequest request) {
                // Detect login form submission
                if (request.url.contains('/login/login')) {
                  _loginAttempted = true;
                }
                // Handle auth redirects
                if (request.url.startsWith('khinsider://auth')) {
                  widget.onLoginSuccess();
                  if (mounted) Navigator.pop(context);
                  return NavigationDecision.prevent;
                }
                return NavigationDecision.navigate;
              },
            ),
          )
          ..loadRequest(Uri.parse(widget.url));
  }

  Future<void> _verifyLoginSuccess() async {
    final directory = await getApplicationDocumentsDirectory();
    final cookieJar = PersistCookieJar(storage: FileStorage(directory.path));

    // 1. First try getting cookies via Android CookieManager
    if (_controller.platform is AndroidWebViewController) {
      final androidController =
          _controller.platform as AndroidWebViewController;
      try {
        final cookies = await androidController.getCookies();
        if (cookies.any((c) => c.name == 'xf_session')) {
          await cookieJar.saveFromResponse(
            Uri.parse('https://downloads.khinsider.com'),
            cookies.map((c) => Cookie(c.name, c.value)).toList(),
          );
          widget.onLoginSuccess();
          if (mounted) Navigator.pop(context);
          return;
        }
      } catch (e) {
        debugPrint('Android cookie error: $e');
      }
    }

    // 2. Fallback to JavaScript cookie check
    try {
      final cookieString =
          await _controller.runJavaScriptReturningResult('document.cookie')
              as String;

      if (cookieString.contains('xf_session')) {
        final cookies =
            cookieString
                .split(';')
                .map((c) => Cookie.fromSetCookieValue(c.trim()))
                .toList();

        await cookieJar.saveFromResponse(
          Uri.parse('https://downloads.khinsider.com'),
          cookies,
        );
        widget.onLoginSuccess();
        if (mounted) Navigator.pop(context);
        return;
      }
    } catch (e) {
      debugPrint('JS cookie error: $e');
    }

    debugPrint('No valid session cookies found');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Login')),
      body: Column(
        children: [
          Expanded(child: WebViewWidget(controller: _controller)),
          if (_loginAttempted)
            const Padding(
              padding: EdgeInsets.all(8.0),
              child: LinearProgressIndicator(),
            ),
        ],
      ),
    );
  }
}

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
    final exportFile = File('${directory.path}/shared_prefs_export.json');

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

class SearchApp extends StatefulWidget {
  const SearchApp({super.key});

  @override
  State<SearchApp> createState() => _SearchAppState();
}

class _SearchAppState extends State<SearchApp> {
  String _themeMode = 'light';

  @override
  void initState() {
    super.initState();
    _loadThemePreference();
  }

  Future<void> _loadThemePreference() async {
    final theme = PreferencesManager.getString('themeMode') ?? 'light';
    setState(() {
      _themeMode = theme;
    });
  }

  void _updateTheme(String theme) {
    setState(() {
      _themeMode = theme;
    });
    PreferencesManager.setString('themeMode', theme);
  }

  ThemeData _getThemeData(String themeMode) {
    switch (themeMode) {
      case 'dark':
        return ThemeData.dark().copyWith(
          scaffoldBackgroundColor: Colors.grey[900],
          primaryColor: Colors.blueAccent,
          colorScheme: const ColorScheme.dark(
            primary: Colors.blueAccent,
            secondary: Colors.teal,
            surface: Colors.grey,
            onSurface: Colors.white,
          ),
          appBarTheme: const AppBarTheme(
            backgroundColor: Colors.grey,
            foregroundColor: Colors.white,
          ),
          elevatedButtonTheme: ElevatedButtonThemeData(
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.blueAccent,
              foregroundColor: Colors.white,
            ),
          ),
          textTheme: const TextTheme(
            bodyMedium: TextStyle(color: Colors.white),
            titleLarge: TextStyle(color: Colors.white),
          ),
          iconTheme: const IconThemeData(color: Colors.white),
          progressIndicatorTheme: const ProgressIndicatorThemeData(
            color: Colors.blueAccent,
          ),
        );
      case 'amoled':
        return ThemeData(
          scaffoldBackgroundColor: Colors.black,
          primaryColor: Colors.blueAccent,
          colorScheme: const ColorScheme.dark(
            primary: Colors.blueAccent,
            secondary: Colors.teal,
            surface: Colors.black,
            onSurface: Colors.white,
          ),
          appBarTheme: const AppBarTheme(
            backgroundColor: Colors.black,
            foregroundColor: Colors.white,
          ),
          elevatedButtonTheme: ElevatedButtonThemeData(
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.blueAccent,
              foregroundColor: Colors.white,
            ),
          ),
          textTheme: const TextTheme(
            bodyMedium: TextStyle(color: Colors.white),
            titleLarge: TextStyle(color: Colors.white),
          ),
          iconTheme: const IconThemeData(color: Colors.white),
          progressIndicatorTheme: const ProgressIndicatorThemeData(
            color: Colors.blueAccent,
          ),
          cardColor: Colors.grey[900],
          dividerColor: Colors.grey[800],
        );
      case 'light':
      default:
        return ThemeData.light().copyWith(
          scaffoldBackgroundColor: Colors.white,
          primaryColor: Colors.blue,
          colorScheme: const ColorScheme.light(
            primary: Colors.blue,
            secondary: Colors.teal,
            surface: Colors.white,
            onSurface: Colors.black,
          ),
          appBarTheme: const AppBarTheme(
            backgroundColor: Colors.blue,
            foregroundColor: Colors.white,
          ),
          elevatedButtonTheme: ElevatedButtonThemeData(
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.blue,
              foregroundColor: Colors.white,
            ),
          ),
          textTheme: const TextTheme(
            bodyMedium: TextStyle(color: Colors.black),
            titleLarge: TextStyle(color: Colors.black),
          ),
          iconTheme: const IconThemeData(color: Colors.black),
          progressIndicatorTheme: const ProgressIndicatorThemeData(
            color: Colors.blue,
          ),
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      theme: _getThemeData(_themeMode),
      home: SearchScreen(onThemeChanged: _updateTheme),
    );
  }
}

class SongState {
  final int index;
  final String? url;

  SongState(this.index, this.url);
}

class SearchScreen extends StatefulWidget {
  final Function(String) onThemeChanged;

  const SearchScreen({super.key, required this.onThemeChanged});

  @override
  State<SearchScreen> createState() => SearchScreenState();
}

class SearchScreenState extends State<SearchScreen>
    with WidgetsBindingObserver {
  final TextEditingController _searchController = TextEditingController();
  final http.Client _httpClient = PersistentHttpClient();
  final AudioPlayer _player = AudioPlayer();
  final AppLinks _appLinks = AppLinks();
  late final ValueNotifier<SongState> _songState;
  bool _isPlayerExpanded = false;
  bool _isShuffleEnabled = false;
  LoopMode _loopMode = LoopMode.off;
  List<Map<String, String>> _albums = [];
  ConcatenatingAudioSource? _playlist;
  List<Map<String, dynamic>> _songs = [];
  Map<String, String>? _selectedAlbum;
  List<Map<String, dynamic>> _playlists = [];
  int _currentNavIndex = 0;
  bool _isPlaylistSelected = false;
  List<String> _albumTypes = ['All'];
  String _selectedType = 'All';
  StreamSubscription? _uriLinkSubscription;
  bool _isDeepLinkLoading = false;
  bool _isLoggedIn = false;

  @override
  void initState() {
    super.initState();
    _songState = ValueNotifier<SongState>(SongState(0, null));
    WidgetsBinding.instance.addObserver(this);
    _init();
    _player.sequenceStateStream.listen((state) {
      if (state == null || _playlist == null) return;
      final index = state.currentIndex;
      _songState.value = SongState(
        index,
        index < _playlist!.children.length
            ? (_playlist!.children[index] as ProgressiveAudioSource).uri
                .toString()
            : null,
      );
      _savePlaybackState();
    });
  }

  Future<void> _init() async {
    await _loadPreferences();
    await _checkLoginStatus();
    if (_isLoggedIn) {
      await _loadPlaylists();
    }
    await _restorePlaybackState();
    await _initDeepLinks();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _uriLinkSubscription?.cancel();
    _player.dispose();
    _httpClient.close();
    _searchController.dispose();
    _songState.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      _savePlaybackState();
    }
  }

  Future<void> _checkLoginStatus() async {
    final prefs = await SharedPreferences.getInstance();
    final url = Uri.parse('https://downloads.khinsider.com/playlist/browse');
    final response = await _httpClient.get(url);
    final isLoggedIn =
        response.statusCode == 200 &&
        !response.body.contains('login') &&
        !response.body.contains('Login') &&
        !response.body.contains('form id="login"');
    debugPrint(
      'Login status check: isLoggedIn=$isLoggedIn, Status: ${response.statusCode}',
    );
    setState(() {
      _isLoggedIn = isLoggedIn;
    });
    await prefs.setBool('isLoggedIn', isLoggedIn);
    if (isLoggedIn) {
      await _loadPlaylists();
    } else {
      debugPrint('Session invalid, clearing cookies');
      final directory = await getApplicationDocumentsDirectory();
      final cookieJar = PersistCookieJar(storage: FileStorage(directory.path));
      await cookieJar.deleteAll();
    }
  }

  Future<void> _savePlaybackState() async {
    final currentSongUrl = _songState.value.url;
    if (currentSongUrl == null || _playlist == null) return;

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('currentSongUrl', currentSongUrl);
    await prefs.setInt('currentSongIndex', _songState.value.index);
    await prefs.setInt('playbackPosition', _player.position.inSeconds);

    final songsJson = jsonEncode(
      _songs.map((song) {
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
          'songPageUrl': song['songPageUrl'],
          'songId': song['songId'],
          'playlistId': song['playlistId'],
        };
      }).toList(),
    );
    await prefs.setString('playlistSongs', songsJson);
  }

  Future<void> _restorePlaybackState() async {
    final prefs = await SharedPreferences.getInstance();
    final currentSongUrl = prefs.getString('currentSongUrl');
    if (currentSongUrl == null) {
      debugPrint('No playback state to restore');
      return;
    }

    final currentSongIndex = prefs.getInt('currentSongIndex') ?? 0;
    final playbackPosition = prefs.getInt('playbackPosition') ?? 0;
    final songsJson = prefs.getString('playlistSongs');

    if (songsJson == null) {
      debugPrint('No playlist songs saved');
      return;
    }

    try {
      final List<dynamic> songsList = jsonDecode(songsJson);
      final restoredSongs =
          songsList.map((item) {
            final map = item as Map<String, dynamic>;
            if (!map.containsKey('id') || !map.containsKey('title')) {
              throw FormatException('Invalid song data: $map');
            }
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
              'runtime': map['runtime'] ?? 'Unknown',
              'albumUrl': map['albumUrl'] ?? '',
              'index': map['index'] ?? 0,
              'songPageUrl': map['songPageUrl'] ?? '',
              'songId': map['songId'] ?? '',
              'playlistId': map['playlistId'] ?? '',
            };
          }).toList();

      setState(() {
        _songs = restoredSongs;
        _playlist = ConcatenatingAudioSource(
          children:
              restoredSongs
                  .map((song) => song['audioSource'] as AudioSource)
                  .toList(),
        );
        _selectedAlbum = null;
      });

      debugPrint(
        'Restored playback: index=$currentSongIndex, url=$currentSongUrl, songCount=${restoredSongs.length}',
      );

      _songState.value = SongState(currentSongIndex, currentSongUrl);

      try {
        await _player.setAudioSource(
          _playlist!,
          initialIndex: currentSongIndex,
        );
        await _player.seek(Duration(seconds: playbackPosition));
      } catch (e) {
        debugPrint('Error setting audio source: $e');
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to restore playback queue: $e')),
        );
      }
    } catch (e) {
      debugPrint('Error restoring playback state: $e');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to restore playback queue: $e')),
      );
    }
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
          if (uri.toString().startsWith('khinsider://auth')) {
            _handleLoginRedirect();
          } else {
            _handleDeepLink(uri);
          }
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

  Future<void> _handleLoginRedirect() async {
    debugPrint('Handling login redirect');
    final prefs = await SharedPreferences.getInstance();
    final directory = await getApplicationDocumentsDirectory();
    final cookieJar = PersistCookieJar(storage: FileStorage(directory.path));
    final cookies = await cookieJar.loadForRequest(
      Uri.parse('https://downloads.khinsider.com'),
    );
    debugPrint('Cookies after login: ${cookies.map((c) => c.name).join(', ')}');

    setState(() {
      _isLoggedIn = true;
    });
    await prefs.setBool('isLoggedIn', true);
    debugPrint('Login state set to true, loading playlists');
    await _loadPlaylists();
  }

  Future<void> _handleDeepLink(Uri uri) async {
    if (uri.host != 'downloads.khinsider.com') {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Unsupported deep link.')));
      return;
    }

    setState(() {
      _isDeepLinkLoading = true;
      _selectedAlbum = null;
      _songs = [];
      _playlist = null;
      _isPlaylistSelected = false;
    });
    _songState.value = SongState(0, null);

    try {
      await _loadPreferences();

      if (uri.path.endsWith('.mp3')) {
        final songData = await _parseSongPage(uri.toString());
        final mp3Url = songData['mp3Url']!;
        final albumUrl = songData['albumUrl']!;
        final songName = songData['songName']!;
        final fallbackAlbumName = songData['albumName']!;
        final songPageUrl = songData['songPageUrl']!;

        if (mp3Url.isEmpty || albumUrl.isEmpty) {
          throw Exception('Invalid song page: missing MP3 or album URL');
        }

        try {
          await _fetchAlbumPage(
            albumUrl.replaceFirst('https://downloads.khinsider.com', ''),
          );

          int songIndex = _songs.indexWhere(
            (song) => song['songPageUrl'] == songPageUrl,
          );
          if (songIndex == -1) {
            songIndex = _songs.indexWhere(
              (song) =>
                  (song['audioSource'] as ProgressiveAudioSource).uri
                      .toString() ==
                  mp3Url,
            );
          }
          if (songIndex == -1) {
            throw Exception('Song not found in album song list');
          }

          setState(() {
            _playlist = ConcatenatingAudioSource(
              children:
                  _songs
                      .map((song) => song['audioSource'] as AudioSource)
                      .toList(),
            );
            _isPlayerExpanded = true;
          });

          await _playAudioSourceAtIndex(songIndex, false);
        } catch (e) {
          debugPrint('Error fetching album page: $e');
          final audioSource = ProgressiveAudioSource(
            Uri.parse(mp3Url),
            tag: MediaItem(
              id: mp3Url,
              title: songName,
              album: fallbackAlbumName,
              artist: fallbackAlbumName,
              artUri: null,
            ),
          );

          final song = {
            'audioSource': audioSource,
            'runtime': 'Unknown',
            'albumUrl': albumUrl.replaceFirst(
              'https://downloads.khinsider.com',
              '',
            ),
            'index': 0,
            'songPageUrl': songPageUrl,
            'songId': '',
            'playlistId': '',
          };

          setState(() {
            _selectedAlbum = {
              'albumName': fallbackAlbumName,
              'albumUrl': albumUrl,
              'imageUrl': '',
              'type': '',
              'year': '',
              'platform': '',
            };
            _songs = [song];
            _playlist = ConcatenatingAudioSource(children: [audioSource]);
            _isPlayerExpanded = true;
          });

          await _playAudioSourceAtIndex(0, false);
        }
      } else if (uri.path.startsWith('/playlist/') &&
          !uri.path.endsWith('/browse')) {
        final playlistUrl = uri.path;
        final playlistData = await _fetchPlaylistPage(playlistUrl);

        if (_songs.isEmpty) {
          throw Exception('Playlist not found or no songs available');
        }

        setState(() {
          _selectedAlbum = {
            'albumName': playlistData['name'] ?? 'Shared Playlist',
            'albumUrl': playlistUrl,
            'imageUrl': playlistData['imageUrl'] ?? '',
            'type': 'Playlist',
            'year': '',
            'platform': '',
          };
          _isPlaylistSelected = true;
          _isPlayerExpanded = false;
        });
      } else if (uri.path.startsWith('/game-soundtracks/album')) {
        final albumUrl = uri.path;
        await _fetchAlbumPage(albumUrl);

        if (_songs.isEmpty) {
          throw Exception('Album not found or no songs available');
        }

        setState(() {
          _isPlayerExpanded = false;
        });
      } else {
        throw Exception('Unsupported deep link');
      }

      setState(() {
        _isDeepLinkLoading = false;
      });
    } catch (e) {
      setState(() {
        _isDeepLinkLoading = false;
      });
      debugPrint('Error handling deep link: $e');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to load song, album, or playlist: $e')),
      );
    }
  }

  Future<Map<String, String>> _parseSongPage(String songPageUrl) async {
    final response = await _httpClient.get(Uri.parse(songPageUrl));
    if (response.statusCode != 200) {
      throw Exception('Failed to load song page: ${response.statusCode}');
    }

    final document = html_parser.parse(response.body);
    final mp3Url = await _fetchActualMp3UrlStatic(songPageUrl);

    final albumLink = document.querySelector(
      'a[href*="/game-soundtracks/album/"]',
    );
    final albumUrl = albumLink?.attributes['href'] ?? '';
    final fullAlbumUrl =
        albumUrl.isNotEmpty ? 'https://downloads.khinsider.com$albumUrl' : '';

    final songNameElement = document.querySelector('p b')?.parent;
    final songName =
        songNameElement != null && songNameElement.text.contains('Song name')
            ? songNameElement.querySelector('b')?.text ?? 'Unknown'
            : 'Unknown';

    final albumNameElement =
        document
            .querySelectorAll('p b')
            .asMap()
            .entries
            .firstWhere(
              (entry) =>
                  entry.value.parent?.text.contains('Album name') ?? false,
              orElse: () => MapEntry(-1, document.createElement('b')),
            )
            .value;
    final albumName =
        albumNameElement.parent!.text.contains('Album name')
            ? albumNameElement.text
            : 'Unknown';

    return {
      'mp3Url': mp3Url,
      'albumUrl': fullAlbumUrl,
      'songName': songName,
      'albumName': albumName,
      'songPageUrl': songPageUrl,
    };
  }

  Future<void> _loadPreferences() async {
    final shuffleEnabled =
        PreferencesManager.getBool('shuffleEnabled') ?? false;
    final loopModeString = PreferencesManager.getString('loopMode') ?? 'off';
    final loopMode =
        {
          'off': LoopMode.off,
          'one': LoopMode.one,
          'all': LoopMode.all,
        }[loopModeString] ??
        LoopMode.off;

    setState(() {
      _isShuffleEnabled = shuffleEnabled;
      _loopMode = loopMode;
    });

    await _player.setShuffleModeEnabled(shuffleEnabled);
    await _player.setLoopMode(loopMode);
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

  Future<void> _loadPlaylists() async {
    try {
      final playlists = await _fetchPlaylists();
      setState(() {
        _playlists = playlists;
      });
      debugPrint('Loaded ${_playlists.length} playlists');
    } catch (e) {
      debugPrint('Error loading playlists: $e');
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Failed to load playlists: $e')));
    }
  }

  Future<List<Map<String, dynamic>>> _fetchPlaylists() async {
    final url = Uri.parse('https://downloads.khinsider.com/playlist/browse');
    final response = await _httpClient.get(url);
    debugPrint('Playlist response status: ${response.statusCode}');
    debugPrint('Playlist response body: ${response.body.substring(0, 500)}');
    if (response.statusCode == 200) {
      if (response.body.contains('login') ||
          response.body.contains('Login') ||
          response.body.contains('form id="login"')) {
        debugPrint('Playlist request redirected to login page');
        final prefs = await SharedPreferences.getInstance();
        await prefs.setBool('isLoggedIn', false);
        setState(() {
          _isLoggedIn = false;
        });
        throw Exception('Session expired or invalid. Please log in again.');
      }
      return await compute(parsePlaylists, response.body);
    } else if (response.statusCode == 401 || response.statusCode == 403) {
      debugPrint('Unauthorized or forbidden access');
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('isLoggedIn', false);
      setState(() {
        _isLoggedIn = false;
      });
      throw Exception('Authentication required. Please log in.');
    } else {
      throw Exception('Failed to load playlists: ${response.statusCode}');
    }
  }

  Future<void> _createPlaylist(String name) async {
    if (name.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Playlist name cannot be empty')),
      );
      return;
    }

    try {
      final url = Uri.parse(
        'https://downloads.khinsider.com/playlist/add?name=${Uri.encodeQueryComponent(name)}',
      );
      final response = await _httpClient.get(url);
      if (response.statusCode == 200) {
        await _loadPlaylists();
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Playlist created successfully')),
        );
      } else {
        throw Exception('Failed to create playlist: ${response.statusCode}');
      }
    } catch (e) {
      debugPrint('Error creating playlist: $e');
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Failed to create playlist: $e')));
    }
  }

  Future<void> _addSongToPlaylists(
    String songId,
    List<String> playlistIds,
  ) async {
    if (!_isLoggedIn) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please log in to add songs to playlists.'),
        ),
      );
      return;
    }

    for (final playlistId in playlistIds) {
      try {
        final url = Uri.parse(
          'https://downloads.khinsider.com/playlist/popup_toggle?songid=$songId&playlistid=$playlistId',
        );
        final response = await _httpClient.get(url);
        if (response.statusCode == 200) {
          debugPrint('Song $songId added to playlist $playlistId successfully');
        } else {
          throw Exception(
            'Failed to add song to playlist: ${response.statusCode}',
          );
        }
      } catch (e) {
        debugPrint('Error adding song $songId to playlist $playlistId: $e');
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to add song to playlist $playlistId: $e'),
          ),
        );
      }
    }
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Song added to selected playlists')),
    );
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
    if (_player.playing) {
      _player.pause();
    } else {
      _player.play();
    }
    _savePlaybackState();
  }

  Future<void> _playAudioSourceAtIndex(int index, bool isPlaylist) async {
    try {
      if (index >= _songs.length) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Cannot play song: invalid index.')),
        );
        return;
      }
      setState(() {
        _playlist = ConcatenatingAudioSource(
          children:
              _songs.map((song) => song['audioSource'] as AudioSource).toList(),
        );
        _isPlaylistSelected = isPlaylist;
        _isPlayerExpanded = true;
      });
      _songState.value = SongState(
        index,
        (_songs[index]['audioSource'] as ProgressiveAudioSource).uri.toString(),
      );
      await _player.setAudioSource(_playlist!, initialIndex: index);
      await _player.play();
      _savePlaybackState();
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
    _savePlaybackState();
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
    _savePlaybackState();
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
        final document = html_parser.parse(response.body);
        final imageUrl = _getHighResImageUrl(
          document.querySelector('.albumImage img')?.attributes['src'] ?? '',
        );

        final albumName =
            document.querySelector('h2')?.text.trim() ?? 'Unknown';
        String type = _selectedAlbum?['type'] ?? '';
        String year = _selectedAlbum?['year'] ?? '';
        String platform = _selectedAlbum?['platform'] ?? '';

        final metadataParagraph = document.querySelector('p[align="left"]');
        if (metadataParagraph != null) {
          final rawInnerHtml = metadataParagraph.innerHtml;
          final metadataLines =
              rawInnerHtml
                  .split(RegExp(r'<br\s*/?>'))
                  .map((line) => line.trim())
                  .toList();
          for (final line in metadataLines) {
            if (line.isEmpty) continue;
            String text = line.replaceAll(RegExp(r'<[^>]+>'), '').trim();
            text = text.replaceAll(RegExp(r'\s+'), ' ');
            if (RegExp(
              r'^(Platforms?|Platform)\s*:',
              caseSensitive: false,
            ).hasMatch(text)) {
              platform =
                  text
                      .replaceFirst(
                        RegExp(
                          r'^(Platforms?|Platform)\s*:',
                          caseSensitive: false,
                        ),
                        '',
                      )
                      .trim();
            } else if (RegExp(
              r'^Year\s*:',
              caseSensitive: false,
            ).hasMatch(text)) {
              year =
                  text
                      .replaceFirst(
                        RegExp(r'^Year\s*:', caseSensitive: false),
                        '',
                      )
                      .trim();
            } else if (RegExp(
              r'^(Album type|Type)\s*:',
              caseSensitive: false,
            ).hasMatch(text)) {
              type =
                  text
                      .replaceFirst(
                        RegExp(r'^(Album type|Type)\s*:', caseSensitive: false),
                        '',
                      )
                      .trim();
            }
          }
        }

        if (type.isEmpty || year.isEmpty || platform.isEmpty) {
          final metaDescription =
              document
                  .querySelector('meta[name="description"]')
                  ?.attributes['content'] ??
              '';
          if (metaDescription.isNotEmpty) {
            final regex = RegExp(
              r'\(([^)]+)\)\s*\((gamerip|soundtrack|singles|arrangements|remixes|compilations|inspired by)\)\s*\((\d{4})\)',
              caseSensitive: false,
            );
            final match = regex.firstMatch(metaDescription);
            if (match != null) {
              if (platform.isEmpty)
                platform = match.group(1)?.trim() ?? platform;
              if (type.isEmpty) type = match.group(2)?.trim() ?? type;
              if (year.isEmpty) year = match.group(3)?.trim() ?? year;
            }
          }
        }

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

        final songs = await compute(parseSongList, {
          'body': response.body,
          'albumName': albumName,
          'imageUrl': imageUrl,
          'albumUrl': albumUrl,
          'isPlaylist': false,
        });

        setState(() {
          _songs = songs;
        });
      } else {
        throw Exception('Failed to load album page: ${response.statusCode}');
      }
    } catch (e) {
      debugPrint('Error occurred while fetching album page: $e');
      throw e;
    }
  }

  Future<Map<String, dynamic>> _fetchPlaylistPage(String playlistUrl) async {
    final fullUrl = 'https://downloads.khinsider.com$playlistUrl';
    try {
      final response = await _httpClient.get(Uri.parse(fullUrl));
      if (response.statusCode == 200) {
        final document = html_parser.parse(response.body);
        final name =
            document
                .querySelector('#playlistTitle')
                ?.text
                .replaceFirst('Playlist:', '')
                .trim()
                .split(RegExp(r'\s*(<a.*)|(\s\s\s.*)'))
                .first ??
            'Shared Playlist';
        final songs = await compute(parseSongList, {
          'body': response.body,
          'albumName': name,
          'imageUrl': '', // Will be set from first song
          'albumUrl': playlistUrl,
          'isPlaylist': true,
        });

        String imageUrl = '';
        if (songs.isNotEmpty) {
          final firstSong = songs.first;
          final mediaItem =
              (firstSong['audioSource'] as ProgressiveAudioSource).tag
                  as MediaItem;
          imageUrl = mediaItem.artUri?.toString() ?? '';
        }

        setState(() {
          _songs = songs;
        });

        return {'name': name, 'imageUrl': imageUrl};
      } else {
        throw Exception('Failed to load playlist page: ${response.statusCode}');
      }
    } catch (e) {
      debugPrint('Error occurred while fetching playlist page: $e');
      throw e;
    }
  }

  String _getHighResImageUrl(String url) {
    return url.replaceFirst('/thumbs/', '/');
  }

  void _shareAlbum(String albumUrl) {
    final shareUrl = 'https://downloads.khinsider.com$albumUrl';
    Share.share(shareUrl, subject: 'Check out this album!');
  }

  void _shareSong(Map<String, dynamic> song) {
    final songPageUrl = song['songPageUrl'] as String?;
    if (songPageUrl == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Song URL not available for sharing.')),
      );
      return;
    }
    final shareUrl = songPageUrl;
    Share.share(shareUrl, subject: 'Check out this song!');
  }

  Future<void> _showAddToPlaylistDialog(String songId) async {
    if (!_isLoggedIn) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please log in to add songs to playlists.'),
        ),
      );
      return;
    }

    final selectedPlaylists = <String>[];
    await showDialog(
      context: context,
      builder:
          (context) => AlertDialog(
            title: const Text('Add to Playlists'),
            content: StatefulBuilder(
              builder:
                  (context, setDialogState) => SizedBox(
                    width: double.maxFinite,
                    child:
                        _playlists.isEmpty
                            ? const Text('No playlists available.')
                            : ListView(
                              shrinkWrap: true,
                              children:
                                  _playlists.map((playlist) {
                                    final playlistId =
                                        (playlist['url'] as String)
                                            .split('/')
                                            .last;
                                    return CheckboxListTile(
                                      title: Text(playlist['name'] as String),
                                      value: selectedPlaylists.contains(
                                        playlistId,
                                      ),
                                      onChanged: (value) {
                                        setDialogState(() {
                                          if (value == true) {
                                            selectedPlaylists.add(playlistId);
                                          } else {
                                            selectedPlaylists.remove(
                                              playlistId,
                                            );
                                          }
                                        });
                                      },
                                    );
                                  }).toList(),
                            ),
                  ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Cancel'),
              ),
              TextButton(
                onPressed: () {
                  if (selectedPlaylists.isNotEmpty) {
                    _addSongToPlaylists(songId, selectedPlaylists);
                  }
                  Navigator.pop(context);
                },
                child: const Text('Add'),
              ),
            ],
          ),
    );
  }

  Future<void> _showCreatePlaylistDialog() async {
    final controller = TextEditingController();
    await showDialog(
      context: context,
      builder:
          (context) => AlertDialog(
            title: const Text('Create Playlist'),
            content: TextField(
              controller: controller,
              decoration: const InputDecoration(
                labelText: 'Playlist Name',
                border: OutlineInputBorder(),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Cancel'),
              ),
              TextButton(
                onPressed: () {
                  _createPlaylist(controller.text);
                  Navigator.pop(context);
                },
                child: const Text('Create'),
              ),
            ],
          ),
    );
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
                          _selectedAlbum = Map<String, String>.from(album);
                          _isPlaylistSelected = false;
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
      return const Center(child: Text('No album or playlist selected.'));
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
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                _selectedAlbum!['albumName'] ?? 'Unknown',
                style: const TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                ),
                textAlign: TextAlign.center,
                softWrap: true,
              ),
              const SizedBox(height: 4),
              Text(
                '${_selectedAlbum!['type']?.isEmpty == true ? 'None' : _selectedAlbum!['type']} - ${_selectedAlbum!['year']} | ${_selectedAlbum!['platform']}',
                style: const TextStyle(color: Colors.grey),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        Center(
          child: IconButton(
            icon: const Icon(Icons.share),
            onPressed: () => _shareAlbum(_selectedAlbum!['albumUrl']!),
          ),
        ),
        const SizedBox(height: 16),
        ..._songs.asMap().entries.map((entry) {
          final index = entry.key;
          final song = entry.value;
          final audioSource = song['audioSource'] as ProgressiveAudioSource;
          final mediaItem = audioSource.tag as MediaItem;
          return ListTile(
            title: Text(
              mediaItem.title ?? 'Unknown',
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: Text(song['runtime'] ?? 'Unknown'),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  icon: const Icon(Icons.playlist_add),
                  onPressed: () => _showAddToPlaylistDialog(song['songId']),
                ),
                IconButton(
                  icon: const Icon(Icons.share),
                  onPressed: () => _shareSong(song),
                ),
              ],
            ),
            onTap: () {
              _playAudioSourceAtIndex(index, _isPlaylistSelected);
            },
          );
        }),
        if (_songState.value.url != null) const SizedBox(height: 70),
      ],
    );
  }

  Widget _buildPlaylistsList() {
    if (!_isLoggedIn) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Text('Please log in to view your playlists.'),
            const SizedBox(height: 16),
            ElevatedButton(
              onPressed: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder:
                        (context) => WebViewScreen(
                          url: 'https://downloads.khinsider.com/forums/login',
                          onLoginSuccess: () async {
                            await _handleLoginRedirect();
                            await _checkLoginStatus();
                          },
                        ),
                  ),
                );
              },
              child: const Text('Log In'),
            ),
          ],
        ),
      );
    }

    if (_playlists.isEmpty) {
      return const Center(child: Text('No playlists found.'));
    }

    return ListView(
      children: [
        const SizedBox(height: 16),
        Center(
          child: Container(
            width: 200,
            height: 200,
            color: Colors.grey[300],
            child: const Icon(
              Icons.playlist_play,
              size: 100,
              color: Colors.blue,
            ),
          ),
        ),
        const SizedBox(height: 12),
        const Text(
          'Playlists',
          style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 24),
        ..._playlists.asMap().entries.map((entry) {
          final index = entry.key;
          final playlist = entry.value;
          return ListTile(
            leading:
                playlist['imageUrl']?.isNotEmpty == true
                    ? CircleAvatar(
                      backgroundImage: NetworkImage(playlist['imageUrl']),
                      radius: 30,
                    )
                    : const CircleAvatar(
                      backgroundColor: Colors.grey,
                      radius: 30,
                      child: Icon(Icons.playlist_play, color: Colors.white),
                    ),
            title: Text(playlist['name'] ?? 'Unknown'),
            subtitle: Text('Songs: ${playlist['songCount'] ?? 0}'),
            onTap: () {
              setState(() {
                _selectedAlbum = {
                  'albumName': playlist['name'],
                  'albumUrl': playlist['url'],
                  'imageUrl': playlist['imageUrl'] ?? '',
                  'type': 'Playlist',
                  'year': '',
                  'platform': '',
                };
                _isPlaylistSelected = true;
              });
              _fetchPlaylistPage(playlist['url']);
            },
          );
        }),
        if (_songState.value.url != null) const SizedBox(height: 70),
      ],
    );
  }

  Widget _buildExpandedPlayer() {
    return ValueListenableBuilder<SongState>(
      valueListenable: _songState,
      builder: (context, songState, child) {
        if (_playlist == null ||
            songState.index >= _playlist!.children.length) {
          return const SizedBox();
        }
        final song =
            (_playlist!.children[songState.index] as ProgressiveAudioSource).tag
                as MediaItem;

        return Material(
          elevation: 12,
          color: Theme.of(context).scaffoldBackgroundColor,
          child: Container(
            height: MediaQuery.of(context).size.height,
            width: MediaQuery.of(context).size.width,
            color: Theme.of(context).scaffoldBackgroundColor,
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
                if (song.artUri != null)
                  ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: Image.network(
                      song.artUri.toString(),
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
                  song.title ?? 'Unknown',
                  style: const TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                  ),
                  textAlign: TextAlign.center,
                ),
                Text(
                  song.album ?? 'Unknown',
                  style: const TextStyle(fontSize: 16, color: Colors.grey),
                  textAlign: TextAlign.center,
                ),
                IconButton(
                  icon: const Icon(Icons.playlist_add),
                  onPressed: () {
                    if (songState.index < _songs.length) {
                      _showAddToPlaylistDialog(
                        _songs[songState.index]['songId'],
                      );
                    }
                  },
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
                        final position = _player.position;
                        if (position.inSeconds <= 2 && songState.index > 0) {
                          _player.seekToPrevious();
                        } else {
                          _player.seek(Duration.zero);
                        }
                      },
                    ),
                    StreamBuilder<PlayerState>(
                      stream: _player.playerStateStream,
                      builder: (context, snapshot) {
                        final playerState = snapshot.data;
                        return IconButton(
                          iconSize: 48.0,
                          icon: Icon(
                            playerState?.playing == true
                                ? Icons.pause
                                : Icons.play_arrow,
                          ),
                          onPressed: _playPause,
                        );
                      },
                    ),
                    IconButton(
                      iconSize: 40.0,
                      icon: const Icon(Icons.skip_next),
                      onPressed: () {
                        if (songState.index < _playlist!.children.length - 1) {
                          _player.seekToNext();
                        }
                      },
                    ),
                    IconButton(
                      iconSize: 40.0,
                      icon: Icon(
                        _loopMode == LoopMode.one
                            ? Icons.repeat_one
                            : Icons.repeat,
                        color:
                            _loopMode != LoopMode.off
                                ? Colors.blue
                                : Colors.grey,
                      ),
                      onPressed: _toggleLoopMode,
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildMiniPlayer() {
    return ValueListenableBuilder<SongState>(
      valueListenable: _songState,
      builder: (context, songState, child) {
        if (_playlist == null ||
            songState.index >= _playlist!.children.length) {
          return const SizedBox();
        }
        final song =
            (_playlist!.children[songState.index] as ProgressiveAudioSource).tag
                as MediaItem;

        return Material(
          elevation: 6,
          color: Theme.of(context).cardColor,
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
                  if (song.artUri != null)
                    ClipRRect(
                      borderRadius: BorderRadius.circular(6),
                      child: Image.network(
                        song.artUri.toString(),
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
                      song.title ?? 'Playing...',
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 16),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.playlist_add),
                    onPressed: () {
                      if (songState.index < _songs.length) {
                        _showAddToPlaylistDialog(
                          _songs[songState.index]['songId'],
                        );
                      }
                    },
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
                        onPressed: _playPause,
                      );
                    },
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Future<bool> _onPop() async {
    if (_isDeepLinkLoading) {
      return false;
    }
    if (_isPlayerExpanded) {
      setState(() {
        _isPlayerExpanded = false;
        SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
      });
      return false;
    }
    if (_selectedAlbum != null && _currentNavIndex == 0) {
      setState(() {
        _selectedAlbum = null;
        _isPlaylistSelected = false;
      });
      return false;
    }
    if (_currentNavIndex != 0) {
      setState(() {
        _currentNavIndex = 0;
        _selectedAlbum = null;
        _isPlaylistSelected = false;
      });
      return false;
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) async {
        if (!didPop) {
          await _onPop();
        }
      },
      child: Scaffold(
        appBar:
            _isPlayerExpanded || _isDeepLinkLoading
                ? null
                : AppBar(
                  title: const Text('KHInsider Search'),
                  leading:
                      _selectedAlbum != null && _currentNavIndex == 0
                          ? IconButton(
                            icon: const Icon(Icons.arrow_back),
                            onPressed: () {
                              setState(() {
                                _selectedAlbum = null;
                                _isPlaylistSelected = false;
                              });
                            },
                          )
                          : null,
                ),
        body: Stack(
          children: [
            if (_isDeepLinkLoading)
              const Center(child: CircularProgressIndicator())
            else
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
                              : _buildPlaylistsList(),
                    ),
                  ],
                ),
              ),
            ValueListenableBuilder<SongState>(
              valueListenable: _songState,
              builder: (context, songState, child) {
                if (songState.url != null && !_isDeepLinkLoading) {
                  return Align(
                    alignment: Alignment.bottomCenter,
                    child: AnimatedSwitcher(
                      duration: const Duration(milliseconds: 300),
                      child:
                          _isPlayerExpanded
                              ? _buildExpandedPlayer()
                              : _buildMiniPlayer(),
                    ),
                  );
                }
                return const SizedBox();
              },
            ),
          ],
        ),
        bottomNavigationBar:
            _isPlayerExpanded || _isDeepLinkLoading
                ? null
                : BottomNavigationBar(
                  currentIndex: _currentNavIndex,
                  onTap: (index) {
                    setState(() {
                      _currentNavIndex = index;
                      _selectedAlbum = null;
                      _isPlaylistSelected = index == 1;
                    });
                    if (index == 2) {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder:
                              (context) => SettingsScreen(
                                onThemeChanged: widget.onThemeChanged,
                              ),
                        ),
                      ).then((_) {
                        setState(() {
                          _currentNavIndex = 0;
                          _selectedAlbum = null;
                          _isPlaylistSelected = false;
                        });
                      });
                    }
                  },
                  items: const [
                    BottomNavigationBarItem(
                      icon: Icon(Icons.search),
                      label: 'Search',
                    ),
                    BottomNavigationBarItem(
                      icon: Icon(Icons.playlist_play),
                      label: 'Playlists',
                    ),
                    BottomNavigationBarItem(
                      icon: Icon(Icons.settings),
                      label: 'Settings',
                    ),
                  ],
                ),
        floatingActionButton:
            _currentNavIndex == 1 && _isLoggedIn && !_isPlayerExpanded
                ? FloatingActionButton(
                  onPressed: _showCreatePlaylistDialog,
                  child: const Icon(Icons.add),
                )
                : null,
      ),
    );
  }
}

class PersistentHttpClient extends http.BaseClient {
  final http.Client _client = http.Client();
  final CookieJar _cookieJar;

  PersistentHttpClient() : _cookieJar = CookieJar();

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final directory = await getApplicationDocumentsDirectory();
    final cookieJar = PersistCookieJar(storage: FileStorage(directory.path));
    final cookies = await cookieJar.loadForRequest(request.url);
    final cookieHeader = cookies
        .map((cookie) => '${cookie.name}=${cookie.value}')
        .join('; ');
    request.headers['Cookie'] = cookieHeader;

    // Browser-like headers
    request.headers['Accept'] =
        'text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,image/apng,*/*;q=0.8';
    request.headers['Accept-Encoding'] = 'gzip, deflate, br, zstd';
    request.headers['Accept-Language'] = 'en-US,en;q=0.9';
    request.headers['Connection'] = 'keep-alive';
    request.headers['User-Agent'] =
        'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/136.0.0.0 Safari/537.36';
    request.headers['Sec-Fetch-Dest'] = 'document';
    request.headers['Sec-Fetch-Mode'] = 'navigate';
    request.headers['Sec-Fetch-Site'] = 'same-origin';
    request.headers['Upgrade-Insecure-Requests'] = '1';

    // Add CSRF token
    final prefs = await SharedPreferences.getInstance();
    final xfToken = prefs.getString('xfToken') ?? '';
    if (xfToken.isNotEmpty) {
      request.headers['XF-CSRF'] =
          xfToken; // Updated to match XenForo convention
    }

    debugPrint('Request: ${request.url}, Cookies: $cookieHeader');
    debugPrint('Request Headers: ${request.headers}');

    final response = await _client.send(request);

    final responseCookies = response.headers['set-cookie'];
    if (responseCookies != null) {
      final cookies =
          responseCookies
              .split(',')
              .map((c) => Cookie.fromSetCookieValue(c))
              .toList();
      await cookieJar.saveFromResponse(request.url, cookies);
      debugPrint('Saved response cookies: ${cookies.length}');
    }

    debugPrint(
      'Response: ${request.url}, Status: ${response.statusCode}, Headers: ${response.headers}',
    );
    return response;
  }

  @override
  void close() => _client.close();
}

class SettingsScreen extends StatelessWidget {
  final Function(String) onThemeChanged;

  const SettingsScreen({super.key, required this.onThemeChanged});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          children: [
            DropdownButton<String>(
              value: PreferencesManager.getString('themeMode') ?? 'light',
              isExpanded: true,
              hint: const Text('Select Theme'),
              items: const [
                DropdownMenuItem(value: 'light', child: Text('Light')),
                DropdownMenuItem(value: 'dark', child: Text('Dark')),
                DropdownMenuItem(value: 'amoled', child: Text('AMOLED Black')),
              ],
              onChanged: (value) {
                if (value != null) {
                  onThemeChanged(value);
                }
              },
            ),
            const SizedBox(height: 16),
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

List<Map<String, dynamic>> parsePlaylists(String htmlBody) {
  final document = html_parser.parse(htmlBody);
  final rows = document.querySelectorAll('table#top40 tr');

  return rows
      .skip(1)
      .map((row) {
        final cols = row.querySelectorAll('td');
        if (cols.length < 3) return null;

        final name = cols[1].querySelector('a')?.text.trim() ?? '';
        final url = cols[1].querySelector('a')?.attributes['href'] ?? '';
        final songCount = cols[2].text.trim();
        final imageUrl = cols[0].querySelector('img')?.attributes['src'] ?? '';

        return {
          'name': name,
          'url': url,
          'songCount': songCount,
          'imageUrl': imageUrl,
        };
      })
      .whereType<Map<String, dynamic>>()
      .toList();
}

Future<List<Map<String, dynamic>>> parseSongList(dynamic input) async {
  final String htmlBody = input['body'] as String;
  final String albumName = input['albumName'] as String;
  final String albumImageUrl = input['imageUrl'] as String;
  final String albumUrl = input['albumUrl'] as String;
  final bool isPlaylist = input['isPlaylist'] as bool;

  final document = html_parser.parse(htmlBody);
  final rows = document.querySelectorAll('#songlist tr');
  final List<Map<String, dynamic>> songs = [];
  final List<Future<Map<String, dynamic>?>> futures = [];
  final pool = Pool(Platform.numberOfProcessors);

  for (var i = 0; i < rows.length; i++) {
    final row = rows[i];
    final clickableRow = row.querySelector('.clickable-row');
    if (clickableRow == null) continue;

    final links = clickableRow.querySelectorAll('a');
    if (links.length < 2) continue;

    final name = links[0].text.trim();
    final runtime = links[1].text.trim();
    final href = links[0].attributes['href'];
    if (href == null || name.isEmpty || runtime.isEmpty) continue;

    final detailUrl = 'https://downloads.khinsider.com$href';
    final albumLink = clickableRow.querySelector(
      'a[href*="/game-soundtracks/album/"]',
    );
    final albumUrlFull = albumLink?.attributes['href'] ?? '';
    final imageUrl =
        row
            .querySelector('.albumIcon img')
            ?.attributes['src']
            ?.replaceFirst('/thumbs_small/', '/') ??
        albumImageUrl;
    final songId = row.attributes['songid'] ?? '';
    final playlistId = row.attributes['playlistid'] ?? '';

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
                  artUri: imageUrl.isNotEmpty ? Uri.parse(imageUrl) : null,
                ),
              );
              return {
                'audioSource': audioSource,
                'runtime': runtime,
                'albumUrl': albumUrlFull.isNotEmpty ? albumUrlFull : albumUrl,
                'index': i,
                'songPageUrl': detailUrl,
                'songId': songId,
                'playlistId': playlistId,
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
