import 'package:flutter/material.dart';
import '../theme.dart';
import '../models/contact.dart';
import '../models/message.dart';
import '../services/signaling_service.dart';
import '../services/relay_service.dart';
import '../services/messages_service.dart';
import '../services/signal_service.dart';
import 'call_screen.dart';

class ChatScreen extends StatefulWidget {
  final Contact contact;
  final SignalingService? signaling;
  final RelayService? relayService;
  final ValueNotifier<bool> connectionNotifier;
  final String? myId;
  final String? myName;
  final Future<void> Function(String peerId, Map<String, dynamic> bundle)? onProcessBundle;
  final Future<void> Function(String peerId, Map<String, dynamic> bundle)? onInitializeSession;
  final Function(String text, bool isSent)? onMessageSaved;
  final MessagesService? messagesService;
  final ValueNotifier<String>? newMessageNotifier;
  final Future<String> Function(String)? onEncrypt;

  const ChatScreen({
    super.key,
    required this.contact,
    this.signaling,
    this.relayService,
    required this.connectionNotifier,
    this.myId,
    this.myName,
    this.onProcessBundle,
    this.onInitializeSession,
    this.onMessageSaved,
    this.messagesService,
    this.newMessageNotifier,
    this.onEncrypt,
  });

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _controller       = TextEditingController();
  final _scrollController = ScrollController();
  List<Message> _messages = [];
  bool _showE2ee = true;

  @override
  void initState() {
    super.initState();
    widget.messagesService?.getMessages(widget.contact.id).then((stored) {
      if (mounted && stored.isNotEmpty) {
        setState(() {
          _messages = stored.map((m) => Message(
            text: m.text, isSent: m.isSent, time: m.time,
          )).toList();
        });
      }
      _scrollToBottom(jump: true);
    });

    widget.newMessageNotifier?.addListener(() {
      if (widget.newMessageNotifier!.value.startsWith(widget.contact.id)) {
        widget.messagesService?.getMessages(widget.contact.id).then((stored) {
          if (mounted) {
            setState(() {
              _messages = stored.map((m) => Message(
                text: m.text, isSent: m.isSent, time: m.time,
              )).toList();
            });
            _scrollToBottom();
          }
        });
      }
    });

    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom(jump: true));
  }

  void _scrollToBottom({bool jump = false}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) return;
      if (jump) {
        _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
      } else {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Future<void> _sendMessage() async {
    final text = _controller.text.trim();
    if (text.isEmpty) return;

    String payload;
    try {
      payload = await _encryptForSend(text);
    } on SignalSessionMissingException {
      final recovered = await _establishSessionAndEncrypt(text);
      if (recovered == null) {
        _showSecureSessionError();
        return;
      }
      payload = recovered;
    } catch (_) {
      _showSecureSessionError();
      return;
    }

    try {
      await _transmitPayload(payload);
    } catch (_) {
      _showSecureSessionError();
      return;
    }

    widget.onMessageSaved?.call(text, true);
    setState(() {
      _messages.add(Message(text: text, isSent: true, time: _currentTime()));
      _controller.clear();
    });
    _scrollToBottom();
  }

  Future<String> _encryptForSend(String text) async {
    final encrypt = widget.onEncrypt;
    if (encrypt == null) throw SignalSessionMissingException(widget.contact.id);
    return encrypt(text);
  }

  Future<String?> _establishSessionAndEncrypt(String text) async {
    try {
      final bundle = await widget.relayService?.getBundle(widget.contact.id);
      if (bundle == null) return null;
      final initializeSession = widget.onInitializeSession ?? widget.onProcessBundle;
      if (initializeSession == null) return null;
      await initializeSession(widget.contact.id, bundle);
      return await _encryptForSend(text);
    } catch (_) {
      return null;
    }
  }

  Future<void> _transmitPayload(String payload) async {
    if (widget.signaling?.isPeerConnected(widget.contact.id) ?? false) {
      await widget.signaling?.sendMessage(widget.contact.id, payload);
    } else {
      widget.relayService?.storeMessage(
        widget.contact.id,
        widget.myId ?? 'unknown',
        payload,
      );
    }
  }

  void _showSecureSessionError() {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Secure session could not be established. Message not sent.'),
      ),
    );
  }

  String _currentTime() {
    final now = DateTime.now();
    final h = now.hour.toString().padLeft(2, '0');
    final m = now.minute.toString().padLeft(2, '0');
    return '$h:$m';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kBg,
      appBar: AppBar(
        backgroundColor: kBg,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: kText),
          onPressed: () => Navigator.pop(context),
        ),
        titleSpacing: 0,
        title: Row(
          children: [
            Stack(
              children: [
                Container(
                  width: 36, height: 36,
                  decoration: BoxDecoration(
                    color: kAccentDim,
                    border: Border.all(color: kBorder),
                    shape: BoxShape.circle,
                  ),
                  child: Center(
                    child: Text(widget.contact.initials,
                      style: const TextStyle(color: kAccent, fontSize: 14,
                        fontWeight: FontWeight.w700)),
                  ),
                ),
                if (widget.contact.online)
                  Positioned(
                    right: 0, bottom: 0,
                    child: Container(
                      width: 10, height: 10,
                      decoration: BoxDecoration(
                        color: kAccent, shape: BoxShape.circle,
                        border: Border.all(color: kBg, width: 2),
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(width: 12),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(widget.contact.name,
                  style: const TextStyle(color: kText, fontSize: 15,
                    fontWeight: FontWeight.w600)),
                const Text('p2p connected · e2e encrypted',
                  style: TextStyle(color: kAccent, fontSize: 10)),
              ],
            ),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.call_outlined, color: kMuted),
            onPressed: () async {
              await widget.signaling?.startVoiceCall(
                widget.contact.id, callerName: widget.myName ?? '');
              if (context.mounted) {
                bool isMuted = false;
                Navigator.push(context, MaterialPageRoute(
                  builder: (_) => StatefulBuilder(
                    builder: (ctx, setS) => CallScreen(
                      contactName: widget.contact.name,
                      isOutgoing: true,
                      isMuted: isMuted,
                      onMuteTap: () {
                        setS(() => isMuted = !isMuted);
                        widget.signaling?.setMicMuted(isMuted);
                      },
                      onHangUp: () {
                        widget.signaling?.endVoiceCall();
                        Navigator.pop(ctx);
                      },
                    ),
                  ),
                ));
              }
            },
          ),
          IconButton(
            icon: const Icon(Icons.more_vert, color: kMuted),
            onPressed: () {},
          ),
          const SizedBox(width: 4),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(1),
          child: Container(height: 1, color: kBorder),
        ),
      ),
      body: Column(
        children: [
          if (_showE2ee)
            GestureDetector(
              onTap: () => setState(() => _showE2ee = false),
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                color: kAccentDim,
                child: const Row(
                  children: [
                    Icon(Icons.lock_outline, color: kAccent, size: 14),
                    SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Messages are end-to-end encrypted. Server never sees them.',
                        style: TextStyle(color: kAccent, fontSize: 11),
                      ),
                    ),
                    Icon(Icons.close, color: kAccent, size: 14),
                  ],
                ),
              ),
            ),
          Expanded(
            child: ListView.builder(
              controller: _scrollController,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              itemCount: _messages.length,
              itemBuilder: (context, index) =>
                  _MessageBubble(message: _messages[index]),
            ),
          ),
          Container(
            decoration: const BoxDecoration(
              border: Border(top: BorderSide(color: kBorder)),
              color: kBg,
            ),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Row(
              children: [
                Expanded(
                  child: Container(
                    decoration: BoxDecoration(
                      color: kSurface,
                      border: Border.all(color: kBorder),
                    ),
                    child: TextField(
                      controller: _controller,
                      style: const TextStyle(color: kText, fontSize: 14),
                      maxLines: null,
                      textInputAction: TextInputAction.send,
                      onSubmitted: (_) => _sendMessage(),
                      decoration: const InputDecoration(
                        hintText: 'Message...',
                        hintStyle: TextStyle(color: kMuted, fontSize: 14),
                        border: InputBorder.none,
                        contentPadding: EdgeInsets.symmetric(
                          horizontal: 14, vertical: 10),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                GestureDetector(
                  onTap: _sendMessage,
                  child: Container(
                    width: 44, height: 44,
                    color: kAccent,
                    child: const Icon(Icons.send, color: kBg, size: 20),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _MessageBubble extends StatelessWidget {
  final Message message;
  const _MessageBubble({required this.message});

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: message.isSent ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.75,
        ),
        child: Column(
          crossAxisAlignment: message.isSent
              ? CrossAxisAlignment.end
              : CrossAxisAlignment.start,
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: message.isSent ? kBubbleSent : kBubbleReceived,
                border: Border.all(
                  color: message.isSent
                      ? const Color(0xFF00CC6A).withValues(alpha: 0.2)
                      : kBorder,
                ),
                borderRadius: BorderRadius.only(
                  topLeft: const Radius.circular(8),
                  topRight: const Radius.circular(8),
                  bottomLeft: Radius.circular(message.isSent ? 8 : 2),
                  bottomRight: Radius.circular(message.isSent ? 2 : 8),
                ),
              ),
              child: Text(
                message.text,
                style: TextStyle(
                  color: message.isSent
                      ? const Color(0xFFB3FFD9)
                      : kText,
                  fontSize: 14, height: 1.5,
                ),
              ),
            ),
            const SizedBox(height: 3),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(message.time,
                  style: const TextStyle(color: kMuted, fontSize: 10)),
                if (message.isSent) ...[
                  const SizedBox(width: 4),
                  const Icon(Icons.done_all, color: kAccent, size: 12),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }
}
