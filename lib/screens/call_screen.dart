import 'package:flutter/material.dart';
import 'dart:async';

const kBg = Color(0xFF080808);
const kAccent = Color(0xFF00FF87);
const kMuted = Color(0xFF555555);
const kText = Color(0xFFF0F0F0);

class CallScreen extends StatefulWidget {
  final String contactName;
  final bool isOutgoing;
  final VoidCallback onHangUp;
  final VoidCallback onMuteTap;
  final bool isMuted;

  const CallScreen({
    super.key,
    required this.contactName,
    required this.isOutgoing,
    required this.onHangUp,
    required this.onMuteTap,
    required this.isMuted,
  });

  @override
  State<CallScreen> createState() => _CallScreenState();
}

class _CallScreenState extends State<CallScreen> {
  int _seconds = 0;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() => _seconds++);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  String get _duration {
    final m = (_seconds ~/ 60).toString().padLeft(2, "0");
    final s = (_seconds % 60).toString().padLeft(2, "0");
    return "$m:$s";
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kBg,
      body: SafeArea(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const SizedBox(height: 60),
            Column(
              children: [
                Container(
                  width: 88, height: 88,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(color: kAccent, width: 2),
                  ),
                  child: const Icon(Icons.person, color: kAccent, size: 48),
                ),
                const SizedBox(height: 20),
                Text(widget.contactName,
                  style: const TextStyle(color: kText, fontSize: 26,
                    fontWeight: FontWeight.w700)),
                const SizedBox(height: 8),
                Text(_duration,
                  style: const TextStyle(color: kMuted, fontSize: 16)),
              ],
            ),
            Padding(
              padding: const EdgeInsets.only(bottom: 60),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  GestureDetector(
                    onTap: widget.onMuteTap,
                    child: Column(
                      children: [
                        Container(
                          width: 64, height: 64,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: widget.isMuted
                              ? kAccent.withAlpha(40)
                              : const Color(0xFF1A1A1A),
                          ),
                          child: Icon(
                            widget.isMuted ? Icons.mic_off : Icons.mic,
                            color: widget.isMuted ? kAccent : kMuted,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(widget.isMuted ? "Unmute" : "Mute",
                          style: const TextStyle(color: kMuted, fontSize: 12)),
                      ],
                    ),
                  ),
                  GestureDetector(
                    onTap: widget.onHangUp,
                    child: Column(
                      children: [
                        Container(
                          width: 72, height: 72,
                          decoration: const BoxDecoration(
                            shape: BoxShape.circle,
                            color: Colors.redAccent,
                          ),
                          child: const Icon(Icons.call_end, color: Colors.white, size: 32),
                        ),
                        const SizedBox(height: 8),
                        const Text("End", style: TextStyle(color: kMuted, fontSize: 12)),
                      ],
                    ),
                  ),
                  Column(
                    children: [
                      Container(
                        width: 64, height: 64,
                        decoration: const BoxDecoration(
                          shape: BoxShape.circle,
                          color: Color(0xFF1A1A1A),
                        ),
                        child: const Icon(Icons.volume_up, color: kMuted),
                      ),
                      const SizedBox(height: 8),
                      const Text("Speaker", style: TextStyle(color: kMuted, fontSize: 12)),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
