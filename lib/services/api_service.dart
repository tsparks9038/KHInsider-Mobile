import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:html/parser.dart' as html_parser;
import 'package:http/http.dart' as http;
import 'package:just_audio/just_audio.dart';
import 'package:just_audio_background/just_audio_background.dart';
import 'package:khinsider_android/models/models.dart';
import 'package:khinsider_android/services/preferences_manager.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pool/pool.dart';

Future<String> getAlbumUrl(String songUrl) async {
  final client = http.Client();
  try {
    final response = await client.get(Uri.parse(songUrl));
    if (response.statusCode != 200) {
      throw Exception('Failed to load song page: ${response.statusCode}');
    }

    final document = html_parser.parse(response.body);
    // Locate the paragraph containing the album link
    final albumParagraph = document.querySelector(
      'p[align="left"] b a[href*="/game-soundtracks/album/"]',
    );
    final albumUrl = albumParagraph?.attributes['href'] ?? '';

    if (albumUrl.isEmpty) {
      throw Exception('Album URL not found in song page');
    }

    // Ensure the URL is fully qualified
    return albumUrl.startsWith('http')
        ? albumUrl
        : 'https://downloads.khinsider.com$albumUrl';
  } catch (e) {
    debugPrint('Error fetching album URL: $e');
    rethrow;
  } finally {
    client.close();
  }
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
          return <String, dynamic>{};
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
          return <String, dynamic>{};
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
        () => fetchActualMp3UrlStatic(detailUrl)
            .then((mp3Url) {
              final audioSource = ProgressiveAudioSource(
                Uri.parse(mp3Url),
                tag: MediaItem(
                  id: mp3Url,
                  title:
                      name.isNotEmpty
                          ? name
                          : 'Unknown Song', // Ensure non-empty title
                  album:
                      albumName.isNotEmpty
                          ? albumName
                          : 'Unknown Album', // Ensure non-empty album
                  artist:
                      albumName.isNotEmpty
                          ? albumName
                          : 'Unknown Artist', // Ensure non-empty artist
                  artUri:
                      albumImageUrl.isNotEmpty
                          ? Uri.parse(albumImageUrl)
                          : null, // Optional artwork
                  duration:
                      runtime.isNotEmpty &&
                              RegExp(r'^\d+:\d{2}$').hasMatch(runtime)
                          ? Duration(
                            minutes: int.parse(runtime.split(':')[0]),
                            seconds: int.parse(runtime.split(':')[1]),
                          )
                          : null, // Optional: Add duration if available
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
              return <String, dynamic>{};
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

Future<String> fetchActualMp3UrlStatic(String detailPageUrl) async {
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
