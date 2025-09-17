import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

class LoginScreen extends StatefulWidget {
  final void Function(WebViewController controller)? onLoginSuccess;

  const LoginScreen({super.key, this.onLoginSuccess});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final bool _isLoginLoading = false;
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
