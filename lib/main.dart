import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:html/dom.dart' as html_parser;
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
import 'package:webview_flutter/webview_flutter.dart';
import 'package:dio_cookie_manager/dio_cookie_manager.dart';
import 'package:dio/dio.dart';
import 'package:cookie_jar/cookie_jar.dart';

class Playlist {
  final String name;
  final String url;
  final int songCount;
  final String? imageUrl; // New: Store small image URL

  Playlist({
    required this.name,
    required this.url,
    required this.songCount,
    this.imageUrl,
  });
}

Future<List<Playlist>> fetchPlaylists() async {
  final cookies = PreferencesManager.getCookies();
  debugPrint('Fetching playlists with cookies: $cookies');
  if (!PreferencesManager.isLoggedIn()) {
    throw Exception('User not logged in');
  }

  final cookieString = cookies.entries
      .map((e) => '${e.key}=${e.value}')
      .join('; ');
  final client = http.Client();
  try {
    final response = await client
        .get(
          Uri.parse('https://downloads.khinsider.com/playlist/browse'),
          headers: {
            'Cookie': cookieString,
            'User-Agent':
                'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/136.0.0.0 Safari/537.36',
            'Accept':
                'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
            'Accept-Encoding': 'gzip, deflate, br',
            'Accept-Language': 'en-US,en;q=0.9',
          },
        )
        .timeout(
          const Duration(seconds: 10),
          onTimeout: () {
            throw TimeoutException('Request to load playlists timed out');
          },
        );

    debugPrint('Playlist GET status: ${response.statusCode}');
    if (response.statusCode != 200) {
      throw Exception('Failed to load playlists: ${response.statusCode}');
    }

    final document = html_parser.parse(response.body);
    final title = document.querySelector('title')?.text.trim();
    debugPrint('Page title: $title');
    if (title == 'Please Log In') {
      throw Exception('Session expired, login required');
    }

    final directory = await getApplicationDocumentsDirectory();
    final file = File('${directory.path}/playlist_page.html');
    await file.writeAsString(response.body);
    debugPrint('Saved playlist HTML to ${file.path}');

    return parsePlaylists(response.body);
  } finally {
    client.close();
  }
}

List<Playlist> parsePlaylists(String htmlBody) {
  final document = html_parser.parse(htmlBody);
  final rows = document.querySelectorAll('#top40 tr');

  debugPrint('Found ${rows.length} rows in #top40 table');

  return rows
      .asMap()
      .entries
      .skip(1) // Skip header
      .map((entry) {
        final index = entry.key;
        final row = entry.value;
        final cols = row.querySelectorAll('td');

        debugPrint(
          'Row $index HTML: ${row.innerHtml.substring(0, row.innerHtml.length > 200 ? 200 : row.innerHtml.length)}...',
        );

        if (cols.length < 3) {
          debugPrint('Skipping row $index: Only ${cols.length} columns');
          return null;
        }

        final url =
            cols[0].querySelector('a')?.attributes['href']?.trim() ?? '';
        final name = cols[1].querySelector('a')?.text.trim() ?? 'Unknown';
        final songCountText = cols[2].text.trim().replaceAll(
          RegExp(r'[^\d]'),
          '',
        );
        final songCount = int.tryParse(songCountText) ?? 0;

        // Extract image URL directly from first column
        final imgElement = cols[0].querySelector('img');
        final imageUrl = imgElement?.attributes['src']?.trim().replaceFirst(
          '/thumbs_small/',
          '/',
        );
        final hasDefaultIcon =
            cols[0].querySelector('.albumIconDefaultSmall') != null;

        debugPrint(
          'Row $index: name=$name, url=$url, songCount=$songCount, imageUrl=$imageUrl, hasDefaultIcon=$hasDefaultIcon',
        );

        if (url.isEmpty || name == 'Unknown') {
          debugPrint('Skipping row $index: Invalid URL or name');
          return null;
        }

        return Playlist(
          name: name,
          url: url,
          songCount: songCount,
          imageUrl: hasDefaultIcon ? null : imageUrl,
        );
      })
      .whereType<Playlist>()
      .toList();
}

class PreferencesManager {
  static const String _backupFileName = 'shared_prefs_backup.json';
  static SharedPreferences? _prefs;

  static Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();
    debugPrint(
      'PreferencesManager initialized with keys: ${_prefs!.getKeys()}',
    );
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

  static Future<bool> setCookies(Map<String, String> cookies) async {
    if (_prefs == null) {
      await init();
    }
    for (var entry in cookies.entries) {
      await _prefs!.setString('cookie_${entry.key}', entry.value);
    }
    await _backupPreferences();
    return true;
  }

  static Map<String, String> getCookies() {
    if (_prefs == null) {
      debugPrint('Warning: _prefs not initialized in getCookies');
      return {};
    }
    final cookies = <String, String>{};
    final keys = _prefs!.getKeys();
    for (var key in keys) {
      if (key.startsWith('cookie_')) {
        final cookieName = key.substring(7);
        final value = _prefs!.getString(key);
        if (value != null) {
          cookies[cookieName] = value;
        }
      }
    }
    return cookies;
  }

  // New: Check if user is logged in
  static bool isLoggedIn() {
    final cookies = getCookies();
    return cookies.containsKey('xf_user') && cookies.containsKey('xf_session');
  }

  // New: Clear cookies (for logout)
  static Future<void> clearCookies() async {
    final keys = _prefs!.getKeys();
    for (var key in keys) {
      if (key.startsWith('cookie_')) {
        await _prefs!.remove(key);
      }
    }
    await _backupPreferences();
  }

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
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await JustAudioBackground.init(
    androidNotificationChannelId: 'com.example.khinsider_android.channel.audio',
    androidNotificationChannelName: 'Audio playback',
    androidNotificationOngoing: true,
  );
  await PreferencesManager.init(); // Ensure this completes
  debugPrint('SharedPreferences initialized');
  runApp(const SearchApp());
}

class LoginScreen extends StatefulWidget {
  final void Function(WebViewController controller)? onLoginSuccess;

  const LoginScreen({super.key, this.onLoginSuccess});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  bool _isLoginLoading = false;
  WebViewController? _webViewController;
  List<Playlist> _playlists = [];
  final TextEditingController _emailController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Login to KHInsider')),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Center(
          child:
              _isLoginLoading
                  ? const CircularProgressIndicator()
                  : Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      TextField(
                        controller: _emailController,
                        decoration: const InputDecoration(
                          labelText: 'Email',
                          border: OutlineInputBorder(),
                        ),
                        keyboardType: TextInputType.emailAddress,
                      ),
                      const SizedBox(height: 16),
                      TextField(
                        controller: _passwordController,
                        decoration: const InputDecoration(
                          labelText: 'Password',
                          border: OutlineInputBorder(),
                        ),
                        obscureText: true,
                      ),
                      const SizedBox(height: 24),
                    ],
                  ),
        ),
      ),
    );
  }
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
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen>
    with WidgetsBindingObserver {
  final TextEditingController _searchController = TextEditingController();
  final http.Client _httpClient = http.Client();
  final AudioPlayer _player = AudioPlayer();
  late final ValueNotifier<SongState> _songState;
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
  List<Playlist> _playlists = []; // New: Store playlists
  Playlist? _selectedPlaylist; // New: Track selected playlist

  WebViewController? _webViewController; // Added: Controller for WebView

  // Add missing controllers
  late final TextEditingController _emailController;
  late final TextEditingController _passwordController;

  // Add missing variable for login loading state
  bool _isLoginLoading = false;
  bool _isSongsLoading = false;

  @override
  void initState() {
    super.initState();
    _songState = ValueNotifier<SongState>(SongState(0, null));
    _emailController = TextEditingController();
    _passwordController = TextEditingController();
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
    await _loadFavorites();
    await _restorePlaybackState();
    debugPrint('Is logged in: ${PreferencesManager.isLoggedIn()}');
    if (PreferencesManager.getCookies().isNotEmpty) {
      try {
        await _loadPlaylists();
      } catch (e) {
        debugPrint('Failed to load playlists on init: $e');
        setState(() {
          _playlists = [];
        });
      }
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _player.dispose();
    _httpClient.close();
    _searchController.dispose();
    _emailController.dispose();
    _passwordController.dispose();
    _songState.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      _savePlaybackState();
    }
  }

  Future<void> _performLogin() async {
    if (_emailController.text.isEmpty || _passwordController.text.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please enter both email and password')),
      );
      return;
    }

    setState(() => _isLoginLoading = true);
    final dio = Dio();
    final cookieJar = CookieJar();
    dio.interceptors.add(CookieManager(cookieJar));

    try {
      dio.options.headers = {
        'User-Agent':
            'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/91.0.4472.124 Safari/537.36',
        'Accept':
            'text/html,application/xhtml+xml,application/xml;q=0.9,image/webp,*/*;q=0.8',
        'Accept-Language': 'en-US,en;q=0.9',
        'Origin': 'https://downloads.khinsider.com',
        'Referer': 'https://downloads.khinsider.com/forums/login',
        'DNT': '1',
      };

      debugPrint('Step 1: Getting CSRF token...');
      const loginUrl = 'https://downloads.khinsider.com/forums/login';
      final getResponse = await dio
          .get(loginUrl)
          .timeout(const Duration(seconds: 10));

      if (getResponse.statusCode != 200) {
        debugPrint(
          'Error getting login page: Status ${getResponse.statusCode}',
        );
        throw Exception('Failed to load login page: ${getResponse.statusCode}');
      }

      final doc = html_parser.parse(getResponse.data);
      final xfToken = doc.querySelector('input[name="_xfToken"]');
      if (xfToken == null || xfToken.attributes['value'] == null) {
        debugPrint('Error getting token: No _xfToken found');
        throw Exception('Missing _xfToken from login page');
      }

      debugPrint('Step 2: Logging in...');
      const postUrl =
          'https://downloads.khinsider.com/forums/index.php?login/login';
      dio.options.headers['Referer'] = loginUrl;
      dio.options.headers['Content-Type'] = 'application/x-www-form-urlencoded';

      final loginData = {
        '_xfToken': xfToken.attributes['value'],
        'login': _emailController.text.trim(),
        'password': _passwordController.text,
        'remember': '1',
        '_xfRedirect': 'https://downloads.khinsider.com/playlist/browse',
      };

      final postResponse = await dio
          .post(
            postUrl,
            data: loginData,
            options: Options(
              followRedirects: false,
              validateStatus:
                  (status) => status != null && status >= 200 && status < 400,
            ),
          )
          .timeout(const Duration(seconds: 10));

      if (postResponse.statusCode != 302 && postResponse.statusCode != 303) {
        debugPrint('❌ Login failed: Status ${postResponse.statusCode}');
        throw Exception(
          'Login failed: did not redirect (status ${postResponse.statusCode})',
        );
      }

      final location = postResponse.headers.value('location');
      if (location == null) {
        debugPrint('No redirect location found');
        throw Exception('No redirect location found');
      }

      final redirectUri =
          location.startsWith('https://')
              ? Uri.parse(location)
              : Uri.parse('https://downloads.khinsider.com$location');

      debugPrint('Trying to load playlist page...');
      dio.options.headers['Referer'] =
          'https://downloads.khinsider.com/playlist/';
      final finalResponse = await dio
          .get(redirectUri.toString())
          .timeout(const Duration(seconds: 10));

      if (finalResponse.statusCode != 200) {
        debugPrint(
          'Failed to load playlist: Status code ${finalResponse.statusCode}',
        );
        throw Exception('Failed to load playlist: ${finalResponse.statusCode}');
      }

      final finalDoc = html_parser.parse(finalResponse.data);
      if (finalDoc.querySelector('a[href*="members"]') == null) {
        debugPrint('Login verification failed');
        await PreferencesManager.clearCookies();
        throw Exception('Login verification failed: User menu not found');
      }

      final cookies = await cookieJar.loadForRequest(redirectUri);
      final cookieMap = {for (var cookie in cookies) cookie.name: cookie.value};
      if (!cookieMap.containsKey('xf_user') ||
          !cookieMap.containsKey('xf_session')) {
        debugPrint('Missing required cookies: xf_user or xf_session');
        await PreferencesManager.clearCookies();
        throw Exception('Login failed: Missing required cookies');
      }
      await PreferencesManager.setCookies(cookieMap);
      debugPrint('Saved cookies: $cookieMap');
      debugPrint(
        'Retrieved cookies after save: ${PreferencesManager.getCookies()}',
      );

      final playlists = parsePlaylists(finalResponse.data);
      if (playlists.isEmpty) {
        debugPrint('No playlists found');
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('No playlists found')));
      } else {
        debugPrint('Playlists:');
        for (var playlist in playlists) {
          debugPrint(
            '- ${playlist.name} (${playlist.songCount} tracks) - https://downloads.khinsider${playlist.url}',
          );
        }
      }

      setState(() {
        _playlists = playlists;
        _emailController.clear();
        _passwordController.clear();
        _isLoginLoading = false;
      });

      debugPrint('✅ Login successful, playlists loaded');
    } catch (e) {
      debugPrint('Login error: $e');
      await PreferencesManager.clearCookies();
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Login failed: $e')));
      }
      setState(() => _isLoginLoading = false);
    } finally {
      dio.close();
    }
  }

  Future<void> _savePlaybackState() async {
    final currentSongUrl = _songState.value.url;
    if (currentSongUrl == null || _playlist == null) return;

    final prefs = await SharedPreferences.getInstance();
    debugPrint('All SharedPreferences keys: ${prefs.getKeys()}');

    await prefs.setString('currentSongUrl', currentSongUrl);
    await prefs.setInt('currentSongIndex', _songState.value.index);
    await prefs.setBool('isFavoritesSelected', _isFavoritesSelected);
    await prefs.setInt('playbackPosition', _player.position.inSeconds);

    final songList = _isFavoritesSelected ? _favorites : _songs;
    final songsJson = jsonEncode(
      songList.map((song) {
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
    final isFavoritesSelected = prefs.getBool('isFavoritesSelected') ?? false;
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
            };
          }).toList();

      setState(() {
        _isFavoritesSelected = isFavoritesSelected;
        _playlist = ConcatenatingAudioSource(
          children:
              restoredSongs
                  .map((song) => song['audioSource'] as AudioSource)
                  .toList(),
        );
        _selectedAlbum = null;
      });

      debugPrint(
        'Restored playback: index=$currentSongIndex, url=$currentSongUrl, isFavorites=$isFavoritesSelected, songCount=${restoredSongs.length}',
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

  Future<void> _loadFavorites() async {
    final favoritesJson = PreferencesManager.getString('favorites');
    if (favoritesJson != null) {
      try {
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
                  artUri:
                      map['artUri'] != null
                          ? Uri.parse(
                            (map['artUri'] as String).replaceFirst(
                              '/thumbs_small/',
                              '/',
                            ),
                          )
                          : null,
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
                };
              }).toList();
        });
        debugPrint('Loaded ${_favorites.length} favorite songs');
      } catch (e) {
        debugPrint('Error loading favorites: $e');
      }
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
          'songPageUrl': song['songPageUrl'],
        };
      }).toList(),
    );
    await PreferencesManager.setString('favorites', favoritesJson);
  }

  Future<bool> _validateSession() async {
    final cookies = PreferencesManager.getCookies();
    debugPrint('Validating session with cookies: $cookies');
    if (!PreferencesManager.isLoggedIn()) {
      debugPrint('Not logged in: missing xf_user or xf_session');
      return false;
    }

    final cookieString = cookies.entries
        .map((e) => '${e.key}=${e.value}')
        .join('; ');
    debugPrint('Cookie string: $cookieString');
    final client = http.Client();
    try {
      final response = await client
          .get(
            Uri.parse('https://downloads.khinsider.com/playlist/browse'),
            headers: {
              'Cookie': cookieString,
              'User-Agent':
                  'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/136.0.0.0 Safari/537.36',
              'Accept':
                  'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
              'Accept-Encoding': 'gzip, deflate, br',
              'Accept-Language': 'en-US,en;q=0.9',
            },
          )
          .timeout(const Duration(seconds: 5));
      debugPrint('Session validation status: ${response.statusCode}');
      debugPrint(
        'Response body snippet: ${response.body.substring(0, response.body.length > 200 ? 200 : response.body.length)}',
      );

      final document = html_parser.parse(response.body);
      final title = document.querySelector('title')?.text.trim();
      debugPrint('Page title: $title');

      final directory = await getApplicationDocumentsDirectory();
      final file = File('${directory.path}/session_validation.html');
      await file.writeAsString(response.body);
      debugPrint('Saved session validation HTML to ${file.path}');

      return response.statusCode == 200 &&
          title == 'My Playlists - KHInsider Video Game Music';
    } catch (e) {
      debugPrint('Session validation failed: $e');
      return false;
    } finally {
      client.close();
    }
  }

  Future<void> _loadPlaylists() async {
    setState(() {
      _isLoginLoading = true;
    });

    try {
      final cookies = PreferencesManager.getCookies();
      final cookieString = cookies.entries
          .map((e) => '${e.key}=${e.value}')
          .join('; ');

      final response = await _httpClient.get(
        Uri.parse('https://downloads.khinsider.com/playlist/browse'),
        headers: {
          'Cookie': cookieString,
          'User-Agent':
              'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/136.0.0.0 Safari/537.36',
        },
      );

      debugPrint('Playlist browse response status: ${response.statusCode}');
      debugPrint(
        'Playlist browse response body (first 1000 chars): ${response.body.substring(0, response.body.length > 1000 ? 1000 : response.body.length)}',
      );

      if (response.statusCode != 200) {
        throw Exception('Failed to load playlists: ${response.statusCode}');
      }

      final directory = await getApplicationDocumentsDirectory();
      final file = File('${directory.path}/playlists.html');
      await file.writeAsString(response.body);
      debugPrint('Saved playlists HTML to ${file.path}');

      final playlists = parsePlaylists(response.body);
      debugPrint('Parsed ${playlists.length} playlists');

      setState(() {
        _playlists = playlists;
        _isLoginLoading = false;
      });
    } catch (e) {
      debugPrint('Error loading playlists: $e');
      setState(() {
        _isLoginLoading = false;
      });
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Failed to load playlists: $e')));
    }
  }

  // New: Refresh session (dummy implementation, always returns false)
  Future<bool> _refreshSession() async {
    final cookies = PreferencesManager.getCookies();
    if (!PreferencesManager.isLoggedIn()) return false;

    final cookieString = cookies.entries
        .map((e) => '${e.key}=${e.value}')
        .join('; ');
    final dio = Dio();
    final cookieJar = CookieJar();
    dio.interceptors.add(CookieManager(cookieJar));

    try {
      dio.options.headers = {
        'User-Agent':
            'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/136.0.0.0 Safari/537.36',
        'Accept':
            'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
        'Accept-Encoding': 'gzip, deflate, br',
        'Accept-Language': 'en-US,en;q=0.9',
        'Cookie': cookieString,
      };

      final response = await dio
          .get('https://downloads.khinsider.com/')
          .timeout(const Duration(seconds: 5));
      if (response.statusCode != 200) return false;

      final newCookies = await cookieJar.loadForRequest(
        Uri.parse('https://downloads.khinsider.com/'),
      );
      final cookieMap = {
        for (var cookie in newCookies) cookie.name: cookie.value,
      };
      if (cookieMap.containsKey('xf_user') &&
          cookieMap.containsKey('xf_session')) {
        await PreferencesManager.setCookies(cookieMap);
        debugPrint('Session refreshed with cookies: $cookieMap');
        return true;
      }
      return false;
    } catch (e) {
      debugPrint('Session refresh failed: $e');
      return false;
    } finally {
      dio.close();
    }
  }

  // New: Fetch songs from a playlist
  Future<void> _fetchPlaylistSongs(String playlistUrl) async {
    setState(() {
      _isSongsLoading = true;
    });

    try {
      final cookies = PreferencesManager.getCookies();
      final cookieString = cookies.entries
          .map((e) => '${e.key}=${e.value}')
          .join('; ');

      final response = await _httpClient.get(
        Uri.parse('https://downloads.khinsider.com$playlistUrl'),
        headers: {
          'Cookie': cookieString,
          'User-Agent':
              'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/136.0.0.0 Safari/537.36',
        },
      );

      if (response.statusCode != 200) {
        throw Exception('Failed to load playlist: ${response.statusCode}');
      }

      final document = html_parser.parse(response.body);
      final songRows = document.querySelectorAll('#songlist tr');

      if (songRows.isEmpty) {
        debugPrint('No rows found in #songlist');
        throw Exception('No songs found in playlist');
      }

      final List<Map<String, dynamic>> songs = [];
      final List<Future<Map<String, dynamic>?>> futures = [];
      final pool = Pool(Platform.numberOfProcessors);

      for (var i = 0; i < songRows.length; i++) {
        final row = songRows[i];
        if (row.id == 'songlist_header' || row.id == 'songlist_footer') {
          debugPrint('Skipping row $i: Header or footer row');
          continue;
        }

        final cells = row.querySelectorAll('td');
        if (cells.length < 8) {
          debugPrint('Skipping row $i: Only ${cells.length} cells found');
          continue;
        }

        final titleCell = cells[3];
        final titleLink = titleCell.querySelector('a');
        if (titleLink == null) {
          debugPrint('Skipping row $i: No title link found');
          continue;
        }

        final name = titleLink.text.trim();
        final href = titleLink.attributes['href'];
        if (href == null || name.isEmpty) {
          debugPrint('Skipping row $i: Missing href or name');
          continue;
        }

        // Extract album name from the small font link
        final albumLink = titleCell.querySelectorAll('a')[1];
        final albumName = albumLink?.text.trim() ?? 'Unknown Album';
        final albumUrl = albumLink?.attributes['href'] ?? '';

        final runtimeCell = cells[4];
        final runtime = runtimeCell.text.trim();
        if (runtime.isEmpty || !RegExp(r'^\d+:\d{2}$').hasMatch(runtime)) {
          debugPrint('Skipping row $i: Invalid runtime format "$runtime"');
          continue;
        }

        final albumIconCell = cells[2];
        final albumArtImg = albumIconCell.querySelector('img');
        final albumArtUrl = albumArtImg?.attributes['src']?.replaceFirst(
          '/thumbs_small/',
          '/',
        );

        final songId = row.attributes['songid'];
        final songPageUrl = 'https://downloads.khinsider.com$href';

        futures.add(
          pool.withResource(
            () => _parseSongPage(songPageUrl)
                .then((songData) {
                  final mp3Url = songData['mp3Url']!;
                  final audioSource = ProgressiveAudioSource(
                    Uri.parse(mp3Url),
                    tag: MediaItem(
                      id: mp3Url,
                      title: name,
                      album:
                          albumName, // Use the actual album name from the playlist
                      artist: albumName,
                      artUri:
                          albumArtUrl != null ? Uri.parse(albumArtUrl) : null,
                    ),
                  );
                  return {
                    'audioSource': audioSource,
                    'runtime': runtime,
                    'albumUrl': albumUrl.replaceFirst(
                      'https://downloads.khinsider.com',
                      '',
                    ),
                    'index': songs.length,
                    'songPageUrl': songPageUrl,
                    'songId': songId,
                  };
                })
                .catchError((e) {
                  debugPrint('Error fetching song: $e');
                  return null;
                }),
          ),
        );
      }

      final results = await Future.wait(futures);
      songs.addAll(results.whereType<Map<String, dynamic>>());

      setState(() {
        _songs = songs;
        _selectedAlbum = {
          'albumName':
              _selectedPlaylist!.name, // Still show playlist name as header
          'albumUrl': playlistUrl,
          'imageUrl':
              _selectedPlaylist!.imageUrl?.replaceFirst(
                '/thumbs_small/',
                '/',
              ) ??
              '',
          'type': 'Playlist',
          'year': '',
          'platform': '',
        };
        _isFavoritesSelected = false;
        _playlist = ConcatenatingAudioSource(
          children:
              songs.map((song) => song['audioSource'] as AudioSource).toList(),
        );
        _isSongsLoading = false;
      });
    } catch (e) {
      debugPrint('Error fetching playlist songs: $e');
      setState(() {
        _isSongsLoading = false;
      });
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Failed to load songs: $e')));
    }
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

  Future<void> _playAudioSourceAtIndex(int index, bool isFavorites) async {
    try {
      final songList = isFavorites ? _favorites : _songs;
      debugPrint(
        'Playing song at index $index, songList length: ${songList.length}, isFavorites: $isFavorites',
      );
      if (index >= songList.length || index < 0) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Cannot play song: invalid index.')),
        );
        return;
      }
      setState(() {
        _playlist = ConcatenatingAudioSource(
          children:
              songList
                  .map((song) => song['audioSource'] as AudioSource)
                  .toList(),
        );
        _isFavoritesSelected = isFavorites;
        _isPlayerExpanded = true;
      });
      _songState.value = SongState(
        index,
        (songList[index]['audioSource'] as ProgressiveAudioSource).uri
            .toString(),
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
    setState(() {
      _isSongsLoading = true; // Start loading
      debugPrint('Fetching album page: $albumUrl, setting isSongsLoading=true');
    });
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
          debugPrint('Raw metadata HTML: "$rawInnerHtml"');
          final metadataLines =
              rawInnerHtml
                  .split(RegExp(r'<br\s*/?>'))
                  .map((line) => line.trim())
                  .toList();
          debugPrint('Split metadata lines: $metadataLines');
          for (final line in metadataLines) {
            if (line.isEmpty) continue;
            String text = line.replaceAll(RegExp(r'<[^>]+>'), '').trim();
            text = text.replaceAll(RegExp(r'\s+'), ' ');
            debugPrint('Cleaned metadata line: "$text"');
            if (text.isEmpty) continue;
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
              debugPrint('Extracted platform: "$platform"');
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
              debugPrint('Extracted year: "$year"');
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
              debugPrint('Extracted type: "$type"');
            }
          }
        } else {
          debugPrint('No metadata paragraph found for $fullUrl');
        }

        if (type.isEmpty || year.isEmpty || platform.isEmpty) {
          final metaDescription =
              document
                  .querySelector('meta[name="description"]')
                  ?.attributes['content'] ??
              '';
          debugPrint('Meta description: "$metaDescription"');
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
              debugPrint(
                'Fallback extracted: platform="$platform", type="$type", year="$year"',
              );
            }
          }
        }

        debugPrint(
          'Final parsed metadata: type="$type", year="$year", platform="$platform"',
        );

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
            'imageUrl': imageUrl.replaceFirst('/thumbs_small/', '/'),
            'albumUrl': albumUrl,
          },
        );

        setState(() {
          _selectedAlbum = {
            'imageUrl': imageUrl.replaceFirst('/thumbs_small/', '/'),
            'albumName': albumName,
            'albumUrl': albumUrl,
            'type': type,
            'year': year,
            'platform': platform,
          };
          _songs = songs;
          _isSongsLoading = false; // End loading
          debugPrint(
            'Album page loaded: ${_songs.length} songs fetched, isSongsLoading=false',
          );
        });
      } else {
        debugPrint('Error: ${response.statusCode}');
        setState(() {
          _isSongsLoading = false; // End loading on error
          debugPrint(
            'Album page fetch failed: status=${response.statusCode}, isSongsLoading=false',
          );
        });
        throw Exception('Failed to load album page: ${response.statusCode}');
      }
    } catch (e) {
      debugPrint('Error occurred while fetching album page: $e');
      setState(() {
        _isSongsLoading = false; // End loading on error
        debugPrint('Album page fetch error: $e, isSongsLoading=false');
      });
      throw e;
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

  // New: Logout function
  void _logout() async {
    await PreferencesManager.clearCookies();
    setState(() {
      _playlists = [];
      _selectedPlaylist = null;
      _songs = [];
      _playlist = null;
      _isFavoritesSelected = false;
      _emailController.clear();
      _passwordController.clear();
    });
    _player.stop();
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Logged out successfully')));
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
    debugPrint(
      'Building song list: isSongsLoading=$_isSongsLoading, selectedAlbum=${_selectedAlbum != null}, songsCount=${_songs.length}',
    );

    if (_isSongsLoading) {
      debugPrint('Showing loading indicator for song list');
      return const Center(child: CircularProgressIndicator());
    }

    if (_selectedAlbum == null) {
      debugPrint('No album or playlist selected');
      return const Center(child: Text('No album or playlist selected.'));
    }

    if (_songs.isEmpty) {
      debugPrint('No songs available for ${_selectedAlbum!['albumName']}');
      return const Center(child: Text('No songs available.'));
    }

    debugPrint(
      'Rendering song list for ${_selectedAlbum!['albumName']} with ${_songs.length} songs',
    );
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
                      errorBuilder: (context, error, stackTrace) {
                        debugPrint('Failed to load album image: $error');
                        return Container(
                          width: 200,
                          height: 200,
                          color: Colors.grey[300],
                          child: const Icon(Icons.music_note, size: 100),
                        );
                      },
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
          final songId = song['songId'] as String?;
          return ListTile(
            title: Text(
              audioSource.tag.title ?? 'Unknown',
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: Text(song['runtime'] ?? 'Unknown'),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  icon: const Icon(Icons.playlist_add),
                  tooltip:
                      songId != null
                          ? 'Add to Playlist'
                          : 'Playlist ID unavailable',
                  onPressed:
                      songId != null && PreferencesManager.isLoggedIn()
                          ? () {
                            debugPrint(
                              'Opening playlist dialog for song: $song',
                            );
                            _showAddToPlaylistDialog(song);
                          }
                          : () => ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text(
                                'Please log in or song ID unavailable',
                              ),
                            ),
                          ),
                ),
                IconButton(
                  icon: const Icon(Icons.share),
                  onPressed: () => _shareSong(song),
                ),
              ],
            ),
            onTap: () {
              debugPrint('Tapped song at index $index: ${mediaItem.title}');
              _playAudioSourceAtIndex(index, false);
            },
          );
        }),
        if (_songState.value.url != null) const SizedBox(height: 70),
      ],
    );
  }

  Future<List<Map<String, dynamic>>> _fetchPlaylistPopup(String songId) async {
    final client = http.Client();
    try {
      final cookies = await PreferencesManager.getCookies();
      if (cookies.isEmpty) {
        debugPrint('Error: No cookies found in PreferencesManager');
        throw Exception('No authentication cookies available');
      }
      final cookieString = cookies.entries
          .map((entry) => "${entry.key}=${entry.value}")
          .join('; ');
      debugPrint('Sending cookies: $cookieString');

      final response = await client
          .get(
            Uri.parse(
              'https://downloads.khinsider.com/playlist/popup_list?songid=$songId',
            ),
            headers: {
              'Cookie': cookieString,
              'User-Agent':
                  'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
            },
          )
          .timeout(const Duration(seconds: 10));

      // Debug: Print raw response (check for errors or unexpected HTML)
      debugPrint('Raw HTML: ${response.body}');

      final document = html_parser.parse(response.body);

      // Try BOTH selectors to see which one works
      var playlistLabels = document.querySelectorAll(
        'label.playlistPopupLabel',
      );
      if (playlistLabels.isEmpty) {
        debugPrint(
          'Warning: No labels found with selector "label.playlistPopupLabel"',
        );
        playlistLabels = document.querySelectorAll('label[playlistid]');
      }

      debugPrint('Found ${playlistLabels.length} labels');
      final playlists = <Map<String, dynamic>>[];
      for (final label in playlistLabels) {
        final checkbox = label.querySelector('input[type="checkbox"]');
        final playlistId = label.attributes['playlistid'];

        // Extract name
        String name = '';
        for (var node in label.nodes) {
          if (node is html_parser.Text && node.text.trim().isNotEmpty) {
            name = node.text.trim();
            break;
          }
        }

        // Robust checked detection
        bool isChecked;
        if (checkbox?.attributes == null) {
          // Fallback to HTML string check
          isChecked = label.innerHtml.contains(' checked');
        } else {
          // Normal attribute check
          isChecked = checkbox?.attributes.containsKey('checked') ?? false;
        }

        if (playlistId != null && name.isNotEmpty) {
          playlists.add({
            'id': playlistId,
            'name': name,
            'isChecked': isChecked,
          });
          debugPrint(
            'Parsed playlist: id=$playlistId, name=$name, isChecked=$isChecked',
          );
        }
      }

      debugPrint('Parsed ${playlists.length} playlists');
      return playlists;
    } catch (e) {
      debugPrint('Error fetching playlist popup: $e');
      rethrow;
    } finally {
      client.close();
    }
  }

  Future<void> _togglePlaylistMembership(
    String songId,
    String playlistId,
  ) async {
    final cookies = PreferencesManager.getCookies();
    final cookieString = cookies.entries
        .map((e) => '${e.key}=${e.value}')
        .join('; ');
    final client = http.Client();

    debugPrint(playlistId);

    try {
      final url = Uri.parse(
        'https://downloads.khinsider.com/playlist/popup_toggle?songid=${Uri.encodeQueryComponent(songId)}&playlistid=${Uri.encodeQueryComponent(playlistId)}',
      );

      debugPrint(url.toString());
      final response = await client
          .get(
            url,
            headers: {
              'Cookie': cookieString,
              'User-Agent':
                  'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/136.0.0.0 Safari/537.36',
              'Accept':
                  'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
              'Accept-Encoding': 'gzip, deflate, br',
              'Accept-Language': 'en-US,en;q=0.9',
            },
          )
          .timeout(const Duration(seconds: 10));

      debugPrint('Toggle playlist status: ${response.statusCode}');
      final document = html_parser.parse(response.body);
      // final title = document.querySelector('title')?.text.trim();
      // debugPrint('Create playlist page title: $title');

      // if (response.statusCode != 200 || title == 'Please Log In') {
      //   throw Exception('Session expired or failed to create playlist');
      // }
    } catch (e) {
      debugPrint('Error toggling playlist: $e');
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Failed to toggle playlist: $e')));
    } finally {
      client.close();
    }
  }

  Future<void> _showAddToPlaylistDialog(Map<String, dynamic> song) async {
    final songId = song['songId'] as String?;
    if (songId == null) {
      debugPrint('Invalid songId: $songId for song: ${song['songPageUrl']}');
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Cannot add song: Invalid or missing playlist ID'),
        ),
      );
      return;
    }

    setState(() => _isLoginLoading = true);
    List<Map<String, dynamic>> playlists;
    try {
      playlists = await _fetchPlaylistPopup(songId);
    } catch (e) {
      setState(() => _isLoginLoading = false);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Failed to load playlists: $e')));
      return;
    }
    setState(() => _isLoginLoading = false);

    if (playlists.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('No playlists available')));
      return;
    }

    final checkboxStates = Map<String, bool>.fromEntries(
      playlists.map((p) => MapEntry(p['id'] as String, p['isChecked'] as bool)),
    );

    if (!mounted) return;
    await showDialog(
      context: context,
      builder:
          (context) => StatefulBuilder(
            builder:
                (context, setDialogState) => AlertDialog(
                  title: const Text('Add to Playlists'),
                  content: SizedBox(
                    width: double.maxFinite,
                    child: ListView(
                      shrinkWrap: true,
                      children:
                          playlists.map((playlist) {
                            final playlistId = playlist['id'] as String;
                            return CheckboxListTile(
                              title: Text(playlist['name'] as String),
                              value: checkboxStates[playlistId] ?? false,
                              onChanged: (value) async {
                                if (value == null) return;
                                setState(() => _isLoginLoading = true);
                                try {
                                  final numericPlaylistId = _extractNumericId(
                                    playlistId,
                                  );
                                  await _togglePlaylistMembership(
                                    songId,
                                    numericPlaylistId,
                                  );
                                  setDialogState(
                                    () => checkboxStates[playlistId] = value,
                                  );
                                } catch (e) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(
                                      content: Text(
                                        'Failed to update playlist: $e',
                                      ),
                                    ),
                                  );
                                } finally {
                                  setState(() => _isLoginLoading = false);
                                }
                              },
                            );
                          }).toList(),
                    ),
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('Close'),
                    ),
                  ],
                ),
          ),
    );
  }

  String _extractNumericId(String id) {
    return id.replaceAll(RegExp(r'[^0-9]'), '');
  }

  Future<void> _createPlaylist() async {
    if (!PreferencesManager.isLoggedIn()) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please log in to create a playlist')),
      );
      return;
    }

    final TextEditingController nameController = TextEditingController();
    final result = await showDialog<String>(
      context: context,
      builder:
          (context) => AlertDialog(
            title: const Text('New Playlist'),
            content: TextField(
              controller: nameController,
              decoration: const InputDecoration(
                labelText: 'Playlist Name',
                border: OutlineInputBorder(),
              ),
              maxLength: 50,
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Cancel'),
              ),
              TextButton(
                onPressed: () {
                  final name = nameController.text.trim();
                  if (name.isEmpty) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('Playlist name cannot be empty'),
                      ),
                    );
                    return;
                  }
                  Navigator.pop(context, name);
                },
                child: const Text('Create'),
              ),
            ],
          ),
    );

    if (result == null || result.isEmpty) return;

    setState(() => _isLoginLoading = true);
    final cookies = PreferencesManager.getCookies();
    final cookieString = cookies.entries
        .map((e) => '${e.key}=${e.value}')
        .join('; ');
    final client = http.Client();

    try {
      final url = Uri.parse(
        'https://downloads.khinsider.com/playlist/add?name=${Uri.encodeQueryComponent(result)}',
      );
      final response = await client
          .get(
            url,
            headers: {
              'Cookie': cookieString,
              'User-Agent':
                  'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/136.0.0.0 Safari/537.36',
              'Accept':
                  'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
              'Accept-Encoding': 'gzip, deflate, br',
              'Accept-Language': 'en-US,en;q=0.9',
            },
          )
          .timeout(const Duration(seconds: 10));

      debugPrint('Create playlist status: ${response.statusCode}');
      final document = html_parser.parse(response.body);
      final title = document.querySelector('title')?.text.trim();
      debugPrint('Create playlist page title: $title');

      if (response.statusCode != 200 || title == 'Please Log In') {
        throw Exception('Session expired or failed to create playlist');
      }

      await _loadPlaylists(); // Refresh playlists
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Playlist "$result" created')));
    } catch (e) {
      debugPrint('Error creating playlist: $e');
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Failed to create playlist: $e')));
    } finally {
      setState(() => _isLoginLoading = false);
      client.close();
    }
  }

  Widget _buildPlaylistsList() {
    if (!PreferencesManager.isLoggedIn() && !_isLoginLoading) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              TextField(
                controller: _emailController,
                decoration: const InputDecoration(
                  labelText: 'Email',
                  border: OutlineInputBorder(),
                ),
                keyboardType: TextInputType.emailAddress,
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _passwordController,
                decoration: const InputDecoration(
                  labelText: 'Password',
                  border: OutlineInputBorder(),
                ),
                obscureText: true,
              ),
              const SizedBox(height: 24),
              _isLoginLoading
                  ? const CircularProgressIndicator()
                  : ElevatedButton(
                    onPressed: () async {
                      await _performLogin();
                      if (PreferencesManager.isLoggedIn()) {
                        await _loadPlaylists();
                      }
                    },
                    child: const Text('Login'),
                  ),
            ],
          ),
        ),
      );
    }

    if (_selectedPlaylist != null) {
      if (_isSongsLoading) {
        debugPrint(
          'Showing loading screen for playlist ${_selectedPlaylist!.name}',
        );
        return const Center(child: CircularProgressIndicator());
      }

      // Use _buildSongList to display playlist songs like an album
      return _buildSongList();
    }

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                'Playlists',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
              ),
              Row(
                children: [
                  IconButton(
                    icon: const Icon(Icons.add),
                    tooltip: 'New Playlist',
                    onPressed: _createPlaylist,
                  ),
                  IconButton(
                    icon: const Icon(Icons.logout),
                    onPressed: _logout,
                  ),
                ],
              ),
            ],
          ),
        ),
        Expanded(
          child:
              _isLoginLoading
                  ? const Center(child: CircularProgressIndicator())
                  : _playlists.isEmpty
                  ? Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Text('No playlists available.'),
                        const SizedBox(height: 16),
                        ElevatedButton(
                          onPressed: _loadPlaylists,
                          child: const Text('Retry'),
                        ),
                      ],
                    ),
                  )
                  : ListView.builder(
                    itemCount: _playlists.length,
                    itemBuilder: (context, index) {
                      final playlist = _playlists[index];
                      debugPrint(
                        'Playlist ${playlist.name} imageUrl: ${playlist.imageUrl}',
                      );
                      return ListTile(
                        leading:
                            playlist.imageUrl != null
                                ? CircleAvatar(
                                  backgroundImage: NetworkImage(
                                    playlist.imageUrl!,
                                  ),
                                  radius: 30,
                                  onBackgroundImageError: (error, stackTrace) {
                                    debugPrint(
                                      'Failed to load art for ${playlist.name}: $error',
                                    );
                                  },
                                )
                                : const CircleAvatar(
                                  backgroundColor: Colors.grey,
                                  radius: 30,
                                  child: Icon(
                                    Icons.playlist_play,
                                    color: Colors.white,
                                  ),
                                ),
                        title: Text(playlist.name),
                        subtitle: Text('${playlist.songCount} songs'),
                        onTap: () {
                          setState(() {
                            _selectedPlaylist = playlist;
                            _isSongsLoading = true;
                          });
                          _fetchPlaylistSongs(playlist.url);
                        },
                      );
                    },
                  ),
        ),
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
                  icon: Icon(
                    _isFavorited(song) ? Icons.favorite : Icons.favorite_border,
                    color: _isFavorited(song) ? Colors.red : null,
                  ),
                  onPressed: () {
                    final songList = _isFavoritesSelected ? _favorites : _songs;
                    if (songState.index < songList.length) {
                      _toggleFavorite(songList[songState.index]);
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
                    icon: Icon(
                      _isFavorited(song)
                          ? Icons.favorite
                          : Icons.favorite_border,
                      color: _isFavorited(song) ? Colors.red : null,
                    ),
                    onPressed: () {
                      final songList =
                          _isFavoritesSelected ? _favorites : _songs;
                      if (songState.index < songList.length) {
                        _toggleFavorite(songList[songState.index]);
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
    if (_isPlayerExpanded) {
      setState(() {
        _isPlayerExpanded = false;
        SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
      });
      return false;
    }
    if (_selectedPlaylist != null && _currentNavIndex == 1) {
      setState(() {
        _selectedPlaylist = null;
        _isFavoritesSelected = false;
      });
      return false;
    }
    if (_selectedAlbum != null && _currentNavIndex == 0) {
      setState(() {
        _selectedAlbum = null;
        _isFavoritesSelected = false;
      });
      return false;
    }
    if (_currentNavIndex != 0) {
      setState(() {
        _currentNavIndex = 0;
        _selectedAlbum = null;
        _isFavoritesSelected = false;
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
            _isPlayerExpanded
                ? null
                : AppBar(
                  title: const Text('KHInsider Search'),
                  leading:
                      (_selectedAlbum != null || _selectedPlaylist != null) &&
                              _currentNavIndex <= 1
                          ? IconButton(
                            icon: const Icon(Icons.arrow_back),
                            onPressed: () {
                              setState(() {
                                _selectedAlbum = null;
                                _selectedPlaylist = null;
                                _isFavoritesSelected = false;
                              });
                            },
                          )
                          : null,
                ),
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
                            : _buildPlaylistsList(),
                  ),
                ],
              ),
            ),
            ValueListenableBuilder<SongState>(
              valueListenable: _songState,
              builder: (context, songState, child) {
                if (songState.url != null) {
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
            _isPlayerExpanded
                ? null
                : BottomNavigationBar(
                  currentIndex: _currentNavIndex,
                  onTap: (index) async {
                    setState(() {
                      _currentNavIndex = index;
                      _selectedAlbum = null;
                      _selectedPlaylist = null;
                      _isFavoritesSelected = index == 1;
                    });
                    if (index == 1 && PreferencesManager.isLoggedIn()) {
                      await _loadPlaylists(); // Refresh playlists when selecting playlists tab
                    } else if (index == 2) {
                      final result = await Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder:
                              (context) => SettingsScreen(
                                onThemeChanged: widget.onThemeChanged,
                              ),
                        ),
                      );
                      setState(() {
                        _currentNavIndex = 0;
                        _selectedAlbum = null;
                        _selectedPlaylist = null;
                        _isFavoritesSelected = false;
                        if (result == 'logout') {
                          _playlists = [];
                          _emailController.clear();
                          _passwordController.clear();
                        }
                      });
                    }
                  },
                  items: const [
                    BottomNavigationBarItem(
                      icon: Icon(Icons.search),
                      label: 'Search',
                    ),
                    BottomNavigationBarItem(
                      icon: Icon(
                        Icons.playlist_play,
                      ), // Changed from Icons.favorite
                      label: 'Playlists', // Changed from 'Favorites'
                    ),
                    BottomNavigationBarItem(
                      icon: Icon(Icons.settings),
                      label: 'Settings',
                    ),
                  ],
                ),
      ),
    );
  }
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
              onPressed:
                  PreferencesManager.isLoggedIn()
                      ? () async {
                        await PreferencesManager.clearCookies();
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text('Logged out successfully'),
                          ),
                        );
                        // Navigate back and force playlist tab to show login UI
                        Navigator.pop(
                          context,
                          'logout',
                        ); // Pass signal to refresh
                      }
                      : null,
              child: const Text('Logout'),
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
          'imageUrl': imageUrl.replaceFirst('/thumbs_small/', '/'),
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
    if (links.length < 2) {
      debugPrint('Skipping row $i: insufficient links');
      continue;
    }

    final name = links[0].text.trim();
    final runtime = links[1].text.trim();
    final href = links[0].attributes['href'];
    if (href == null || name.isEmpty || runtime.isEmpty) {
      debugPrint('Skipping row $i: missing href, name, or runtime');
      continue;
    }

    final detailUrl = 'https://downloads.khinsider.com$href';
    final addToPlaylistCell = row.querySelector(
      '.playlistAddCell .playlistAddTo',
    );
    final songId = addToPlaylistCell?.attributes['songid'];

    if (songId == null) {
      debugPrint('Warning: No songid for song "$name" at $detailUrl');
    } else {
      debugPrint('Extracted songid: $songId for song "$name"');
    }

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
                'songPageUrl': detailUrl,
                'songId': songId, // Add songId
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

  if (songs.isEmpty) {
    debugPrint('No songs parsed from album HTML');
  } else {
    debugPrint('Parsed ${songs.length} songs');
  }

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
