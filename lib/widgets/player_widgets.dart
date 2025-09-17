import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:just_audio_background/just_audio_background.dart';

class ExpandedPlayer extends StatelessWidget {
  final MediaItem song;
  final AudioPlayer player;
  final VoidCallback onCollapse;
  final VoidCallback onPlayPause;
  final VoidCallback onToggleShuffle;
  final VoidCallback onToggleLoopMode;
  final VoidCallback? onAddToPlaylist;
  final VoidCallback onPrevious;
  final VoidCallback onNext;
  final bool isShuffleEnabled;
  final LoopMode loopMode;
  final bool canAddToPlaylist;
  final String Function(Duration) formatDuration;

  const ExpandedPlayer({
    super.key,
    required this.song,
    required this.player,
    required this.onCollapse,
    required this.onPlayPause,
    required this.onToggleShuffle,
    required this.onToggleLoopMode,
    this.onAddToPlaylist,
    required this.onPrevious,
    required this.onNext,
    required this.isShuffleEnabled,
    required this.loopMode,
    required this.canAddToPlaylist,
    required this.formatDuration,
  });

  @override
  Widget build(BuildContext context) {
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
                onPressed: onCollapse,
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
              song.title,
              style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
              textAlign: TextAlign.center,
            ),
            Text(
              song.album ?? 'Unknown',
              style: const TextStyle(fontSize: 16, color: Colors.grey),
              textAlign: TextAlign.center,
            ),
            IconButton(
              icon: const Icon(Icons.playlist_add),
              tooltip:
                  canAddToPlaylist
                      ? 'Add to Playlist'
                      : 'Please log in to add to playlist',
              onPressed: onAddToPlaylist,
            ),
            const Spacer(),
            StreamBuilder<Duration>(
              stream: player.positionStream,
              builder: (context, snapshot) {
                final position = snapshot.data ?? Duration.zero;
                final duration = player.duration ?? Duration.zero;
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
                        player.seek(Duration(seconds: value.toInt()));
                      },
                    ),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(formatDuration(position)),
                        Text(formatDuration(duration)),
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
                    color: isShuffleEnabled ? Colors.blue : Colors.grey,
                  ),
                  onPressed: onToggleShuffle,
                ),
                IconButton(
                  iconSize: 40.0,
                  icon: const Icon(Icons.skip_previous),
                  onPressed: onPrevious,
                ),
                StreamBuilder<PlayerState>(
                  stream: player.playerStateStream,
                  builder: (context, snapshot) {
                    final playerState = snapshot.data;
                    return IconButton(
                      iconSize: 48.0,
                      icon: Icon(
                        playerState?.playing == true
                            ? Icons.pause
                            : Icons.play_arrow,
                      ),
                      onPressed: onPlayPause,
                    );
                  },
                ),
                IconButton(
                  iconSize: 40.0,
                  icon: const Icon(Icons.skip_next),
                  onPressed: onNext,
                ),
                IconButton(
                  iconSize: 40.0,
                  icon: Icon(
                    loopMode == LoopMode.one ? Icons.repeat_one : Icons.repeat,
                    color: loopMode != LoopMode.off ? Colors.blue : Colors.grey,
                  ),
                  onPressed: onToggleLoopMode,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class MiniPlayer extends StatelessWidget {
  final MediaItem song;
  final AudioPlayer player;
  final VoidCallback onExpand;
  final VoidCallback onPlayPause;
  final VoidCallback? onAddToPlaylist;
  final bool canAddToPlaylist;

  const MiniPlayer({
    super.key,
    required this.song,
    required this.player,
    required this.onExpand,
    required this.onPlayPause,
    this.onAddToPlaylist,
    required this.canAddToPlaylist,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      elevation: 6,
      color: Theme.of(context).cardColor,
      child: InkWell(
        onTap: onExpand,
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
                  song.title,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 16),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.playlist_add),
                tooltip:
                    canAddToPlaylist
                        ? 'Add to Playlist'
                        : 'Please log in to add to playlist',
                onPressed: onAddToPlaylist,
              ),
              StreamBuilder<PlayerState>(
                stream: player.playerStateStream,
                builder: (context, snapshot) {
                  final playerState = snapshot.data;
                  return IconButton(
                    icon: Icon(
                      playerState?.playing == true
                          ? Icons.pause
                          : Icons.play_arrow,
                    ),
                    onPressed: onPlayPause,
                  );
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}
