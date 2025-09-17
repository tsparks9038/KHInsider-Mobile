import 'package:flutter/material.dart';
import 'package:khinsider_android/services/preferences_manager.dart';

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
