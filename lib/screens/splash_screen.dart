import 'package:flutter/material.dart';
import '../theme.dart';
import '../services/identity_service.dart';
import '../services/biometric_service.dart';
import '../services/startup_latency.dart';
import 'biometric_screen.dart';
import 'contacts_screen.dart';
import 'setup_screen.dart';

class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> {
  final _identity = IdentityService();

  @override
  void initState() {
    super.initState();
    _checkIdentity();
  }

  Future<void> _checkIdentity() async {
    StartupLatency.mark('identity_load_start', data: {'screen': 'splash'});
    await _identity.initialize();
    StartupLatency.mark(
      'identity_load_end',
      data: {'screen': 'splash', 'peerId': _identity.peerId ?? 'missing'},
    );
    if (!mounted) return;

    if (_identity.isSetup) {
      final bioEnabled = await BiometricService.isEnabled();
      final bioAvailable = await BiometricService.isAvailable();
      if (bioEnabled && bioAvailable) {
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(
            builder: (_) =>
                const BiometricScreen(destination: ContactsScreen()),
          ),
        );
        return;
      }
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (_) => const ContactsScreen()),
      );
    } else {
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(
          builder: (ctx) => SetupScreen(
            onComplete: () => Navigator.of(ctx).pushAndRemoveUntil(
              MaterialPageRoute(builder: (_) => const ContactsScreen()),
              (route) => false,
            ),
          ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kBg,
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 12,
              height: 12,
              decoration: const BoxDecoration(
                color: kAccent,
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(height: 16),
            const Text(
              'Mercury',
              style: TextStyle(
                color: kText,
                fontSize: 28,
                fontWeight: FontWeight.w700,
                letterSpacing: -1,
              ),
            ),
            const SizedBox(height: 32),
            const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(color: kAccent, strokeWidth: 2),
            ),
          ],
        ),
      ),
    );
  }
}
