import 'package:flutter/material.dart';
import 'package:khinsider_android/models/models.dart';

class PlaylistListWidget extends StatelessWidget {
  final bool isLoggedIn;
  final bool isLoading;
  final List<Playlist> playlists;
  final void Function()? onLogin;
  final void Function()? onCreatePlaylist;
  final void Function()? onLogout;
  final void Function(Playlist) onPlaylistTap;
  final TextEditingController emailController;
  final TextEditingController passwordController;
  final void Function()? onPerformLogin;

  const PlaylistListWidget({
    super.key,
    required this.isLoggedIn,
    required this.isLoading,
    required this.playlists,
    this.onLogin,
    this.onCreatePlaylist,
    this.onLogout,
    required this.onPlaylistTap,
    required this.emailController,
    required this.passwordController,
    this.onPerformLogin,
  });

  @override
  Widget build(BuildContext context) {
    if (!isLoggedIn && !isLoading) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              TextField(
                controller: emailController,
                decoration: const InputDecoration(
                  labelText: 'Your name or email address',
                  border: OutlineInputBorder(),
                ),
                keyboardType: TextInputType.emailAddress,
              ),
              const SizedBox(height: 16),
              TextField(
                controller: passwordController,
                decoration: const InputDecoration(
                  labelText: 'Password',
                  border: OutlineInputBorder(),
                ),
                obscureText: true,
              ),
              const SizedBox(height: 24),
              isLoading
                  ? const CircularProgressIndicator()
                  : ElevatedButton(
                    onPressed: onPerformLogin,
                    child: const Text('Login'),
                  ),
            ],
          ),
        ),
      );
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
                    onPressed: onCreatePlaylist,
                  ),
                  IconButton(
                    icon: const Icon(Icons.logout),
                    onPressed: onLogout,
                  ),
                ],
              ),
            ],
          ),
        ),
        Expanded(
          child:
              isLoading
                  ? const Center(child: CircularProgressIndicator())
                  : playlists.isEmpty
                  ? Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Text('No playlists available.'),
                        const SizedBox(height: 16),
                        ElevatedButton(
                          onPressed: onLogin,
                          child: const Text('Retry'),
                        ),
                      ],
                    ),
                  )
                  : ListView.builder(
                    itemCount: playlists.length,
                    itemBuilder: (context, index) {
                      final playlist = playlists[index];
                      return ListTile(
                        leading:
                            playlist.imageUrl != null
                                ? CircleAvatar(
                                  backgroundImage: NetworkImage(
                                    playlist.imageUrl!,
                                  ),
                                  radius: 30,
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
                        onTap: () => onPlaylistTap(playlist),
                      );
                    },
                  ),
        ),
      ],
    );
  }
}
