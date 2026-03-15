import '../services/ringtone_service.dart';
import 'package:flutter/material.dart';

const kBg = Color(0xFF080808);
const kAccent = Color(0xFF00FF87);
const kMuted = Color(0xFF555555);
const kText = Color(0xFFF0F0F0);

class IncomingCallScreen extends StatefulWidget {
  final String callerName;
  final VoidCallback onAccept;
  final VoidCallback onDecline;

  const IncomingCallScreen({
    super.key,
    required this.callerName,
    required this.onAccept,
    required this.onDecline,
  });

  @override
  State<IncomingCallScreen> createState() => _IncomingCallScreenState();
}

class _IncomingCallScreenState extends State<IncomingCallScreen> {
  @override
  void initState() {
    super.initState();
    RingtoneService.startRinging();
  }

  @override
  void dispose() {
    RingtoneService.stopRinging();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kBg,
      body: SafeArea(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const SizedBox(height: 80),
            Column(
              children: [
                Container(
                  width: 100, height: 100,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(color: kAccent, width: 2),
                  ),
                  child: const Icon(Icons.person, color: kAccent, size: 56),
                ),
                const SizedBox(height: 24),
                Text(widget.callerName,
                  style: const TextStyle(color: kText, fontSize: 28,
                    fontWeight: FontWeight.w700)),
                const SizedBox(height: 8),
                const Text("Incoming call...",
                  style: TextStyle(color: kMuted, fontSize: 14)),
              ],
            ),
            Padding(
              padding: const EdgeInsets.only(bottom: 80),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  // Decline
                  GestureDetector(
                    onTap: widget.onDecline,
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
                        const Text("Decline",
                          style: TextStyle(color: kMuted, fontSize: 12)),
                      ],
                    ),
                  ),
                  // Accept
                  GestureDetector(
                    onTap: widget.onAccept,
                    child: Column(
                      children: [
                        Container(
                          width: 72, height: 72,
                          decoration: const BoxDecoration(
                            shape: BoxShape.circle,
                            color: kAccent,
                          ),
                          child: const Icon(Icons.call, color: Colors.black, size: 32),
                        ),
                        const SizedBox(height: 8),
                        const Text("Accept",
                          style: TextStyle(color: kMuted, fontSize: 12)),
                      ],
                    ),
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
