import 'dart:async';
import 'package:flutter/material.dart';
import 'package:just_audio_background/just_audio_background.dart';
import 'package:just_audio_media_kit/just_audio_media_kit.dart';
import 'package:khinsider_android/services/preferences_manager.dart';
import 'package:khinsider_android/screens/search_screen.dart';
import 'package:app_links/app_links.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await JustAudioBackground.init(
    androidNotificationChannelId:
        'com.tsparks9038.khinsider_android.channel.audio',
    androidNotificationChannelName: 'Audio Playback',
    androidNotificationOngoing: true,
    androidShowNotificationBadge: true, // Optional: Show notification badge
    androidNotificationIcon:
        'mipmap/ic_launcher', // Ensure you have a proper icon
  );
  JustAudioMediaKit.ensureInitialized();
  await PreferencesManager.init();
  debugPrint('SharedPreferences initialized');
  runApp(const SearchApp());
}

class SearchApp extends StatefulWidget {
  const SearchApp({super.key});

  @override
  State<SearchApp> createState() => _SearchAppState();
}

class _SearchAppState extends State<SearchApp> {
  String _themeMode = 'light';
  final AppLinks _appLinks = AppLinks();
  StreamSubscription<Uri>? _linkSubscription;
  final GlobalKey<SearchScreenState> _searchScreenKey =
      GlobalKey<SearchScreenState>(); // New: GlobalKey

  @override
  void initState() {
    super.initState();
    _loadThemePreference();
    _initDeepLinks();
  }

  Future<void> _initDeepLinks() async {
    try {
      final initialUri = await _appLinks.getInitialLink();
      if (initialUri != null && mounted) {
        _handleDeepLink(initialUri);
      }
    } catch (e) {
      debugPrint('Error handling initial deep link: $e');
    }

    _linkSubscription = _appLinks.uriLinkStream.listen(
      (Uri? uri) {
        if (uri != null && mounted) {
          _handleDeepLink(uri);
        }
      },
      onError: (e) {
        debugPrint('Error in deep link stream: $e');
      },
    );
  }

  void _handleDeepLink(Uri uri) {
    // Delegate to SearchScreen via GlobalKey
    final searchScreenState = _searchScreenKey.currentState;
    if (searchScreenState != null && mounted) {
      searchScreenState.handleDeepLink(uri);
    } else {
      debugPrint('SearchScreen state not available for deep link: $uri');
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Unable to process deep link')),
      );
    }
  }

  @override
  void dispose() {
    _linkSubscription?.cancel();
    super.dispose();
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
    // [Existing _getThemeData implementation remains unchanged]
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
      home: SearchScreen(
        key: _searchScreenKey, // Assign GlobalKey
        onThemeChanged: _updateTheme,
      ),
    );
  }
}
