import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
//import 'package:just_audio_background/just_audio_background.dart';

class SongListWidget extends StatelessWidget {
  final Map<String, String>? selectedAlbum;
  final List<Map<String, dynamic>> songs;
  final void Function(int) onSongTap;
  final void Function(Map<String, dynamic>) onAddToPlaylist;
  final void Function(Map<String, dynamic>) onShareSong;

  const SongListWidget({
    super.key,
    required this.selectedAlbum,
    required this.songs,
    required this.onSongTap,
    required this.onAddToPlaylist,
    required this.onShareSong,
  });

  @override
  Widget build(BuildContext context) {
    if (selectedAlbum == null) {
      return const Center(child: Text('No album or playlist selected.'));
    }

    if (songs.isEmpty) {
      return const Center(child: Text('No songs available.'));
    }

    return ListView(
      children: [
        const SizedBox(height: 16),
        Center(
          child:
              selectedAlbum!['imageUrl']?.isNotEmpty == true
                  ? ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: Image.network(
                      selectedAlbum!['imageUrl']!,
                      width: 200,
                      height: 200,
                      fit: BoxFit.cover,
                      errorBuilder: (context, error, stackTrace) {
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
                selectedAlbum!['albumName'] ?? 'Unknown',
                style: const TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                ),
                textAlign: TextAlign.center,
                softWrap: true,
              ),
              const SizedBox(height: 4),
              Text(
                '${selectedAlbum!['type']?.isEmpty == true ? 'None' : selectedAlbum!['type']} - ${selectedAlbum!['year']} | ${selectedAlbum!['platform']}',
                style: const TextStyle(color: Colors.grey),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
        ...songs.asMap().entries.map((entry) {
          final index = entry.key;
          final song = entry.value;
          final audioSource = song['audioSource'] as ProgressiveAudioSource;
          //final mediaItem = audioSource.tag as MediaItem;
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
                      songId != null ? () => onAddToPlaylist(song) : null,
                ),
                IconButton(
                  icon: const Icon(Icons.share),
                  onPressed: () => onShareSong(song),
                ),
              ],
            ),
            onTap: () => onSongTap(index),
          );
        }),
        if (songs.isNotEmpty) const SizedBox(height: 70),
      ],
    );
  }
}
