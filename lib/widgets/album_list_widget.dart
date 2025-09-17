import 'package:flutter/material.dart';

class AlbumListWidget extends StatelessWidget {
  final List<Map<String, String>> albums;
  final String selectedType;
  final List<String> albumTypes;
  final void Function(String) onTypeChanged;
  final void Function(Map<String, String>) onAlbumTap;

  const AlbumListWidget({
    super.key,
    required this.albums,
    required this.selectedType,
    required this.albumTypes,
    required this.onTypeChanged,
    required this.onAlbumTap,
  });

  @override
  Widget build(BuildContext context) {
    final filteredAlbums =
        selectedType == 'All'
            ? albums
            : albums
                .where(
                  (album) =>
                      (album['type']!.isEmpty ? 'None' : album['type']!) ==
                      selectedType,
                )
                .toList();

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8.0),
          child: DropdownButton<String>(
            value: selectedType,
            isExpanded: true,
            hint: const Text('Filter by Type'),
            items:
                albumTypes.map((type) {
                  return DropdownMenuItem<String>(
                    value: type,
                    child: Text(type),
                  );
                }).toList(),
            onChanged: (value) => onTypeChanged(value ?? 'All'),
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
                          backgroundImage: NetworkImage(album['imageUrl']!),
                          radius: 30,
                        )
                        : const CircleAvatar(
                          backgroundColor: Colors.grey,
                          radius: 30,
                          child: Icon(Icons.music_note, color: Colors.white),
                        ),
                title: Text(album['albumName']!),
                subtitle: Text(
                  '${album['type']!.isEmpty ? 'None' : album['type']} - ${album['year']} | ${album['platform']}',
                ),
                onTap: () => onAlbumTap(album),
              );
            },
          ),
        ),
      ],
    );
  }
}
