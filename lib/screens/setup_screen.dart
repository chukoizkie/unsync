import 'package:flutter/material.dart';
import '../theme.dart';
import '../services/identity_service.dart';

class SetupScreen extends StatefulWidget {
  final VoidCallback onComplete;
  const SetupScreen({super.key, required this.onComplete});

  @override
  State<SetupScreen> createState() => _SetupScreenState();
}

class _SetupScreenState extends State<SetupScreen> {
  final _nameController = TextEditingController();
  final _identity       = IdentityService();
  bool _loading = false;

  Future<void> _createIdentity() async {
    final name = _nameController.text.trim();
    if (name.isEmpty) return;
    if (!mounted) return;
    setState(() => _loading = true);
    await _identity.initialize();
    await _identity.setDisplayName(name);
    if (!mounted) return;
    widget.onComplete();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kBg,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Spacer(),
              Row(
                children: [
                  Container(
                    width: 10, height: 10,
                    decoration: const BoxDecoration(
                      color: kAccent, shape: BoxShape.circle),
                  ),
                  const SizedBox(width: 12),
                  const Text('Mercury',
                    style: TextStyle(color: kText, fontSize: 32,
                      fontWeight: FontWeight.w700, letterSpacing: -1)),
                ],
              ),
              const SizedBox(height: 16),
              const Text('No phone number.\nNo email.\nJust you.',
                style: TextStyle(color: kMuted, fontSize: 18, height: 1.6)),
              const Spacer(),
              const Text('What should people call you?',
                style: TextStyle(color: kText, fontSize: 14,
                  fontWeight: FontWeight.w600)),
              const SizedBox(height: 12),
              Container(
                decoration: BoxDecoration(
                  color: kSurface, border: Border.all(color: kBorder)),
                child: TextField(
                  controller: _nameController,
                  style: const TextStyle(color: kText, fontSize: 16),
                  decoration: const InputDecoration(
                    hintText: 'Display name...',
                    hintStyle: TextStyle(color: kMuted),
                    border: InputBorder.none,
                    contentPadding: EdgeInsets.all(16),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              GestureDetector(
                onTap: _loading ? null : _createIdentity,
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  color: _loading ? kMuted : kAccent,
                  child: Center(
                    child: _loading
                        ? const SizedBox(
                            width: 20, height: 20,
                            child: CircularProgressIndicator(
                              color: kBg, strokeWidth: 2))
                        : const Text('Create Identity',
                            style: TextStyle(color: kBg, fontSize: 16,
                              fontWeight: FontWeight.w700)),
                  ),
                ),
              ),
              const SizedBox(height: 24),
              const Text(
                '🔒 Your identity is stored only on this device.\nWe never see it.',
                style: TextStyle(color: kMuted, fontSize: 11, height: 1.5),
                textAlign: TextAlign.center,
              ),
              const Spacer(),
            ],
          ),
        ),
      ),
    );
  }
}
