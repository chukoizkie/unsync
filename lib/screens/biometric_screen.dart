import 'package:flutter/material.dart';
import '../theme.dart';
import '../services/biometric_service.dart';

class BiometricScreen extends StatefulWidget {
  final Widget destination;
  const BiometricScreen({super.key, required this.destination});

  @override
  State<BiometricScreen> createState() => _BiometricScreenState();
}

class _BiometricScreenState extends State<BiometricScreen> {
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    Future.delayed(const Duration(milliseconds: 400), _authenticate);
  }

  Future<void> _authenticate() async {
    setState(() => _failed = false);
    try {
      final result = await BiometricService.authenticate();
      if (result && mounted) {
        Navigator.pushReplacement(context,
          MaterialPageRoute(builder: (_) => widget.destination));
      } else if (mounted) {
        setState(() => _failed = true);
      }
    } catch (_) {
      if (mounted) setState(() => _failed = true);
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
            const Text('unsync',
              style: TextStyle(color: kText, fontSize: 28,
                fontWeight: FontWeight.w700, letterSpacing: -1)),
            const SizedBox(height: 8),
            Text(
              _failed ? 'Authentication failed' : 'Touch fingerprint sensor',
              style: TextStyle(
                color: _failed ? Colors.redAccent : kMuted,
                fontSize: 13,
              ),
            ),
            const SizedBox(height: 24),
            GestureDetector(
              onTap: _authenticate,
              child: Container(
                width: 72, height: 72,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: kAccent.withAlpha(20),
                  border: Border.all(
                    color: _failed ? Colors.redAccent : kAccent,
                    width: 1.5,
                  ),
                ),
                child: Icon(Icons.fingerprint,
                  color: _failed ? Colors.redAccent : kAccent, size: 40),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
