import 'package:flutter/material.dart';
import 'dart:async';
import '../theme.dart';

class CallScreen extends StatefulWidget {
  final String contactName;
  final bool isOutgoing;
  final VoidCallback onHangUp;
  final VoidCallback onMuteTap;
  final bool isMuted;
  final ValueNotifier<bool>? callAnsweredNotifier;
  final ValueNotifier<dynamic>? remoteStreamNotifier;

  const CallScreen({
    super.key,
    required this.contactName,
    required this.isOutgoing,
    required this.onHangUp,
    required this.onMuteTap,
    required this.isMuted,
    this.callAnsweredNotifier,
    this.remoteStreamNotifier,
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
    widget.callAnsweredNotifier?.addListener(_onCallAnswered);
    widget.remoteStreamNotifier?.addListener(_onRemoteStream);

    // The stream may already have been set by SignalingService before this
    // screen mounted (e.g. createAnswer's onTrack firing inside acceptCall(),
    // which is awaited before this screen is pushed). addListener only fires
    // on future changes, so the current value must be checked explicitly.
    final initialStream = widget.remoteStreamNotifier?.value;
    print('[CALL] CallScreen initial remote stream: $initialStream');
    if (initialStream != null) {
      print('[CALL] CallScreen remote stream attached: $initialStream');
    }
  }

  void _onCallAnswered() {
    print('[CALL] active call screen received call-answered event');
  }

  void _onRemoteStream() {
    final stream = widget.remoteStreamNotifier?.value;
    if (stream == null) {
      print('[CALL] CallScreen remote stream cleared');
      return;
    }
    print('[CALL] CallScreen remote stream attached: $stream');
  }

  @override
  void dispose() {
    _timer?.cancel();
    widget.callAnsweredNotifier?.removeListener(_onCallAnswered);
    widget.remoteStreamNotifier?.removeListener(_onRemoteStream);
    super.dispose();
  }

  String get _duration {
    final m = (_seconds ~/ 60).toString().padLeft(2, '0');
    final s = (_seconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
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
                        Text(widget.isMuted ? 'Unmute' : 'Mute',
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
                          child: const Icon(Icons.call_end,
                            color: Colors.white, size: 32),
                        ),
                        const SizedBox(height: 8),
                        const Text('End',
                          style: TextStyle(color: kMuted, fontSize: 12)),
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
                      const Text('Speaker',
                        style: TextStyle(color: kMuted, fontSize: 12)),
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
