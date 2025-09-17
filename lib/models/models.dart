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

class SongState {
  final int index;
  final String? url;

  SongState(this.index, this.url);
}
