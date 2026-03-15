import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'services/identity_service.dart';
import 'screens/setup_screen.dart';
import 'services/signaling_service.dart';
import 'services/call_notification_service.dart';
import 'services/message_notification_service.dart';
import 'services/relay_service.dart';
import 'services/contacts_service.dart';
import 'services/signal_service.dart';
import 'services/foreground_service.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'services/fcm_service.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'screens/qr_screen.dart';
import 'screens/call_screen.dart';
import 'screens/incoming_call_screen.dart';
import 'screens/biometric_screen.dart';
import 'services/biometric_service.dart';
import 'package:firebase_core/firebase_core.dart';

import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart' as signal;
import 'services/messages_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp();
  FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.light,
    systemNavigationBarColor: Color(0xFF080808),
    systemNavigationBarIconBrightness: Brightness.light,
  ));
  runApp(const UnsyncApp());
}

// ── THEME COLORS ─────────────────────────────────────────────────────────────
const kBg = Color(0xFF080808);
const kSurface = Color(0xFF111111);
const kBorder = Color(0xFF1E1E1E);
const kAccent = Color(0xFF00FF87);
const kAccentDim = Color(0x1400FF87);
const kMuted = Color(0xFF555555);
const kText = Color(0xFFF0F0F0);
const kBubbleSent = Color(0xFF0D2B1E);
const kBubbleReceived = Color(0xFF161616);

// ── MOCK DATA ─────────────────────────────────────────────────────────────────
class Contact {
  final String id;
  final String name;
  final String initials;
  final String lastMessage;
  final String time;
  final bool online;
  final int unread;

  const Contact({
    required this.id,
    required this.name,
    required this.initials,
    required this.lastMessage,
    required this.time,
    required this.online,
    this.unread = 0,
  });
}

class Message {
  final String text;
  final bool isSent;
  final String time;
  final bool delivered;

  const Message({
    required this.text,
    required this.isSent,
    required this.time,
    this.delivered = true,
  });
}

final mockContacts = [
  const Contact(
    id: '1', name: 'Ahmad', initials: 'A',
    lastMessage: 'Server never sees this message.',
    time: '10:43', online: true, unread: 2,
  ),
  const Contact(
    id: '2', name: 'Maria', initials: 'M',
    lastMessage: 'Call me when you\'re free',
    time: '09:21', online: true, unread: 0,
  ),
  const Contact(
    id: '3', name: 'Dev Team', initials: 'D',
    lastMessage: 'Phase 1 complete 🔥',
    time: 'Yesterday', online: false, unread: 0,
  ),
  const Contact(
    id: '4', name: 'Bossing', initials: 'B',
    lastMessage: 'Unsync is live!',
    time: 'Yesterday', online: false, unread: 0,
  ),
];

final mockMessages = [
  const Message(text: 'Hey, is this actually private?', isSent: false, time: '10:42'),
  const Message(text: 'Server never sees this message. Direct to you.', isSent: true, time: '10:42'),
  const Message(text: 'No logs?', isSent: false, time: '10:43'),
  const Message(text: 'Nothing to log. We\'re a phone directory, not a database.', isSent: true, time: '10:43'),
  const Message(text: 'This is wild. So even if they seize the server...', isSent: false, time: '10:44'),
  const Message(text: 'Nothing to find. We cannot comply with what we don\'t have.', isSent: true, time: '10:44'),
  const Message(text: 'Phone lost = evidence gone 😄', isSent: false, time: '10:45'),
  const Message(text: 'Exactly. That\'s not a bug. That\'s the feature.', isSent: true, time: '10:45'),
];

// ── APP ───────────────────────────────────────────────────────────────────────
class UnsyncApp extends StatelessWidget {
  const UnsyncApp({super.key});

  @override
  Widget build(BuildContext context) {
    return WithForegroundTask(
      child: MaterialApp(
      title: 'Unsync',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: kBg,
        colorScheme: const ColorScheme.dark(
          primary: kAccent,
          surface: kSurface,
        ),
        fontFamily: 'Roboto',
        useMaterial3: true,
      ),
      home: const SplashScreen(),
    ),
    );
  }
}

// ── CONTACTS SCREEN ───────────────────────────────────────────────────────────
class ContactsScreen extends StatefulWidget {
  const ContactsScreen({super.key});

  @override
  State<ContactsScreen> createState() => _ContactsScreenState();
}

class _ContactsScreenState extends State<ContactsScreen> {
  int _selectedTab = 0;
  final _signaling = SignalingService();
  final _identity = IdentityService();
  final _contactsService = ContactsService();
  final _messagesService = MessagesService();
  final _signalService = SignalService();
  final _relayService = RelayService();
  bool _connected = false;
  List<SavedContact> _realContacts = [];
  final Map<String, List<StoredMessage>> _messages = {};
  final _newMessageNotifier = ValueNotifier<String>('');
  final _connectionNotifier = ValueNotifier<bool>(false);

  @override
  void initState() {
    super.initState();
    _connect();
  }

  Future<void> _connect() async {
    try {
      ForegroundServiceManager.init();
      await _identity.initialize();
      await Future.microtask(() => _signalService.initialize());
      await _contactsService.initialize();
      if (mounted) setState(() {
        _realContacts = _contactsService.contacts.toList();
      });
      final id = _identity.peerId ?? DateTime.now().millisecondsSinceEpoch.toString();
      await CallNotificationService.initialize();
      await MessageNotificationService.initialize();
      // Handle case where app was launched by tapping notification (killed state)
      final initialCallerId = await CallNotificationService.getInitialCallerId();
      if (initialCallerId != null) {
        // Wait for signaling to connect before showing call screen
        for (int i = 0; i < 20; i++) {
          await Future.delayed(const Duration(milliseconds: 500));
          if (_signaling.myId != null) break;
        }
        if (mounted) {
          CallNotificationService.onNotificationTapped?.call(initialCallerId);
        }
      }
      CallNotificationService.onNotificationTapped = (callerId) {
        final saved = _realContacts.firstWhere(
          (c) => c.peerId == callerId,
          orElse: () => SavedContact(peerId: callerId, displayName: callerId, addedAt: DateTime.now()),
        );
        if (!mounted) return;
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => IncomingCallScreen(
              callerName: saved.displayName,
              onDecline: () {
                _signaling.declineCall();
                try { CallNotificationService.cancel(); } catch (_) {}
                Navigator.pop(context);
              },
              onAccept: () async {
                try { CallNotificationService.cancel(); } catch (_) {}
                await _signaling.acceptCall();
                if (context.mounted) {
                  Navigator.pushReplacement(
                    context,
                    MaterialPageRoute(
                      builder: (_) => StatefulBuilder(
                        builder: (ctx, setS) {
                          bool isMuted = false;
                          return CallScreen(
                            contactName: saved.displayName,
                            isOutgoing: false,
                            isMuted: isMuted,
                            onMuteTap: () {
                              setS(() => isMuted = !isMuted);
                              _signaling.setMicMuted(isMuted);
                            },
                            onHangUp: () {
                              _signaling.endVoiceCall();
                              Navigator.pop(ctx);
                            },
                          );
                        },
                      ),
                    ),
                  );
                }
              },
            ),
          ),
        );
      };
      final fcmToken = await FCMService.initialize();
      await _relayService.connect(id);
      // Upload our pre-key bundle to relay for async messaging
      Future.delayed(const Duration(seconds: 2), () async {
        try {
          final bundle = await _signalService.buildPreKeyBundle();
          _relayService.uploadBundle(id, {
            'registrationId': bundle.getRegistrationId(),
            'identityKey': base64Encode(bundle.getIdentityKey().serialize()),
            'preKeyId': bundle.getPreKeyId(),
            'preKey': base64Encode(bundle.getPreKey()!.serialize()),
            'signedPreKeyId': bundle.getSignedPreKeyId(),
            'signedPreKey': base64Encode(bundle.getSignedPreKey()!.serialize()),
            'signedPreKeySignature': base64Encode(bundle.getSignedPreKeySignature() ?? Uint8List(0)),
          });
          print('Relay: pre-key bundle uploaded');
        } catch (e) {
          print('Relay: bundle upload failed: $e');
        }
      });
      _relayService.onQueuedMessage = (from, payload) async {
        String text = payload;
        if (_signalService.isInitialized) {
          try {
            // Ensure Signal session exists — fetch sender bundle if needed
            if (!_signalService.hasSession(from)) {
              final senderBundle = await _relayService.fetchBundle(from);
              if (senderBundle != null) {
                await _signalService.processPreKeyBundleFromMap(from, senderBundle);
                print('Relay: established Signal session with $from for decryption');
              }
            }
            text = await _signalService.decrypt(from, payload);
          } catch (e) {
            print('Relay decrypt error: $e');
          }
        }
        _messagesService.addMessage(from, text, false);
        _newMessageNotifier.value = '$from:${DateTime.now().millisecondsSinceEpoch}';
        MessageNotificationService.playMessageSound();
        final senderName1 = _realContacts.firstWhere(
          (c) => c.peerId == from,
          orElse: () => SavedContact(peerId: from, displayName: from, addedAt: DateTime.now()),
        ).displayName;
        MessageNotificationService.showMessageNotification(senderName1, text);
        print('Relay: queued message delivered from $from');
      };
      print('Connecting to signaling with id: ${id}');
      _signaling.onConnectionStateChanged = (connected) {
        print('Connection state changed: $connected');
        _connectionNotifier.value = connected;
        if (mounted) setState(() => _connected = connected);
      };
      _signaling.onPeerOffline = (peerId) {
        print('Peer offline: $peerId — switching to relay');
        _connectionNotifier.value = false;
        if (mounted) setState(() => _connected = false);
      };

      _signaling.onIncomingCall = (peerId) async {
        final saved = _realContacts.firstWhere(
          (c) => c.peerId == peerId,
          orElse: () => SavedContact(peerId: peerId, displayName: peerId, addedAt: DateTime.now()),
        );
        await CallNotificationService.showIncomingCall(saved.displayName, peerId);
        if (!mounted) return;
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => IncomingCallScreen(
              callerName: saved.displayName,
              onDecline: () {
                _signaling.declineCall();
                try { CallNotificationService.cancel(); } catch (_) {}
                Navigator.pop(context);
              },
              onAccept: () async {
                try { CallNotificationService.cancel(); } catch (_) {}
                await _signaling.acceptCall();
                if (context.mounted) {
                  Navigator.pushReplacement(
                    context,
                    MaterialPageRoute(
                      builder: (_) => StatefulBuilder(
                        builder: (ctx, setS) {
                          bool isMuted = false;
                          return CallScreen(
                            contactName: saved.displayName,
                            isOutgoing: false,
                            isMuted: isMuted,
                            onMuteTap: () {
                              setS(() => isMuted = !isMuted);
                              _signaling.setMicMuted(isMuted);
                            },
                            onHangUp: () {
                              _signaling.endVoiceCall();
                              Navigator.pop(ctx);
                            },
                          );
                        },
                      ),
                    ),
                  );
                }
              },
            ),
          ),
        );
      };

      _signaling.onCallEnded = () {
        try { CallNotificationService.cancel(); } catch (_) {}
        if (mounted) {
          Navigator.of(context).popUntil((route) => route.isFirst);
        }
      };
      _signaling.onMessageReceived = (peerId, msg) async {
        print('Message received from peerId: $peerId msg: $msg');
        // Check if handshake
        try {
          final parsed = jsonDecode(msg);
          if (parsed['type'] == 'handshake') {
            final name = parsed['name'] as String;
            final id = parsed['peerId'] as String;
            _contactsService.addContact(id, name).then((_) {
              if (mounted) setState(() {
                _realContacts = _contactsService.contacts.toList();
              });
            });
            // Process Signal Protocol pre-key bundle
            if (parsed['signalBundle'] != null) {
              final b = parsed['signalBundle'];
              try {
                final bundle = signal.PreKeyBundle(
                  b['registrationId'],
                  1,
                  b['preKeyId'],
                  signal.Curve.decodePoint(base64Decode(b['preKey'] as String), 0),
                  b['signedPreKeyId'],
                  signal.Curve.decodePoint(base64Decode(b['signedPreKey'] as String), 0),
                  base64Decode(b['signedPreKeySignature'] as String),
                  signal.IdentityKey.fromBytes(base64Decode(b['identityKey'] as String), 0),
                );
                _signalService.processPreKeyBundle(id, bundle);
                print('Signal session established with $id');
              } catch (e) {
                print('Signal bundle error: $e');
              }
            }
            return;
          }
        } catch (_) {}
        // Regular message - decrypt if Signal session exists
        String plaintext = msg;
        if (_signalService.isInitialized) {
          try {
            plaintext = await _signalService.decrypt(peerId, msg);
          } catch (e) {
            print('Decrypt error: $e — treating as plaintext');
          }
        }
        _messagesService.addMessage(peerId, plaintext, false).then((_) async {
          final msgs = await _messagesService.getMessages(peerId);
          if (mounted) setState(() {
            _messages[peerId] = msgs;
            _newMessageNotifier.value = '$peerId:${DateTime.now().millisecondsSinceEpoch}';
            MessageNotificationService.playMessageSound();
            final senderName2 = _realContacts.firstWhere(
              (c) => c.peerId == peerId,
              orElse: () => SavedContact(peerId: peerId, displayName: peerId, addedAt: DateTime.now()),
            ).displayName;
            MessageNotificationService.showMessageNotification(senderName2, plaintext);
          });
        });
      };
      // Send handshake when peer connects
      _signaling.onPeerConnected = (peerId) async {
        _connectionNotifier.value = true;
        final myName = _identity.displayName ?? 'Unknown';
        final myId = _identity.peerId ?? '';
        final bundle = await _signalService.buildPreKeyBundle();
        _signaling.sendMessage(peerId, jsonEncode({
          'type': 'handshake',
          'name': myName,
          'peerId': myId,
          'signalBundle': {
            'registrationId': bundle.getRegistrationId(),
            'identityKey': base64Encode(bundle.getIdentityKey().serialize()),
            'preKeyId': bundle.getPreKeyId(),
            'preKey': base64Encode(bundle.getPreKey()!.serialize()),
            'signedPreKeyId': bundle.getSignedPreKeyId(),
            'signedPreKey': base64Encode(bundle.getSignedPreKey()!.serialize()),
            'signedPreKeySignature': base64Encode(bundle.getSignedPreKeySignature()!),
          }
        }));
      };
      await _signaling.connect(id, fcmToken: await FCMService.getToken());
      print('Signaling connect() completed');
      ForegroundServiceManager.start();
      // Reconnect when FCM ping arrives while app is backgrounded
      FirebaseMessaging.onMessage.listen((message) {
        print('FCM ping — checking relay connection');
        if (!_relayService.isConnected) {
          _relayService.connect(id);
        }
      });
      // Auto-reconnect to saved contacts (only lower ID initiates)
      if (_realContacts.isNotEmpty) {
        print('Auto-reconnecting to ${_realContacts.length} saved contacts...');
        await Future.delayed(const Duration(seconds: 2));
        for (final contact in _realContacts) {
          if (id.compareTo(contact.peerId) < 0) {
            print('Will connect to: ${contact.peerId} on demand');
          } else {
            print('Waiting for: ${contact.peerId} to initiate');
          }
        }
      }
    } catch (e, stack) {
      print('Connect error: $e');
      print(stack);
    }
  }

  @override
  void dispose() {
    _signaling.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kBg,
      appBar: AppBar(
        backgroundColor: kBg,
        elevation: 0,
        titleSpacing: 20,
        title: Row(
          children: [
            Container(
              width: 8, height: 8,
              decoration: BoxDecoration(
                color: _connected ? kAccent : kMuted,
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 10),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'unsync',
                  style: TextStyle(
                    color: kText,
                    fontSize: 20,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -0.5,
                  ),
                ),
                Text(
                  _connected ? 'mesh connected' : 'connecting...',
                  style: TextStyle(
                    color: _connected ? kAccent : kMuted,
                    fontSize: 10,
                  ),
                ),
              ],
            ),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.qr_code_scanner_outlined, color: kMuted),
            onPressed: () => _openQR(context),
          ),
          IconButton(
            icon: const Icon(Icons.more_vert, color: kMuted),
            onPressed: () => _showSettings(context),
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
          // Debug banner
          if (!_connected)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              color: const Color(0xFF1A1A00),
              child: const Text('⚡ connecting to mesh...',
                style: TextStyle(color: kAccent, fontSize: 11)),
            ),
          if (_connected)
            GestureDetector(
              onTap: () {
                final id = _signaling.myId ?? 'unknown';
                showDialog(
                  context: context,
                  builder: (_) => AlertDialog(
                    backgroundColor: kSurface,
                    title: const Text('Your Peer ID', style: TextStyle(color: kText)),
                    content: SelectableText(id,
                      style: const TextStyle(color: kAccent, fontSize: 12, fontFamily: 'monospace')),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(context),
                        child: const Text('Close', style: TextStyle(color: kAccent)),
                      ),
                    ],
                  ),
                );
              },
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                color: const Color(0xFF001A0D),
                child: Text('✅ mesh connected — tap to see your ID',
                  style: const TextStyle(color: kAccent, fontSize: 11)),
              ),
            ),
          // Debug: Connect to peer
          // Search bar
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Container(
              decoration: BoxDecoration(
                color: kSurface,
                border: Border.all(color: kBorder),
              ),
              child: const TextField(
                style: TextStyle(color: kText, fontSize: 14),
                decoration: InputDecoration(
                  hintText: 'Search contacts...',
                  hintStyle: TextStyle(color: kMuted, fontSize: 14),
                  prefixIcon: Icon(Icons.search, color: kMuted, size: 20),
                  border: InputBorder.none,
                  contentPadding: EdgeInsets.symmetric(vertical: 12),
                ),
              ),
            ),
          ),

          // Tabs
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              children: [
                Expanded(child: _buildTab('Messages', 0)),
                const SizedBox(width: 8),
                Expanded(child: _buildTab('Calls', 1)),
              ],
            ),
          ),

          // Contact list
          Expanded(
            child: ListView.separated(
              itemCount: _realContacts.length,
              separatorBuilder: (_, __) => Container(height: 1, color: kBorder),
              itemBuilder: (context, index) {
                if (index >= _realContacts.length) return const SizedBox.shrink();
                final contact = Contact(
                      id: _realContacts[index].peerId,
                      name: _realContacts[index].displayName,
                      initials: _realContacts[index].displayName.substring(0, 1).toUpperCase(),
                      lastMessage: _selectedTab == 0 ? 'Tap to chat' : 'Tap to call',
                      time: '',
                      online: true,
                    );
                return _ContactTile(
                  contact: contact,
                  onLongPress: () => _showContactOptions(context, contact),
                  onTap: () {
                    if (_selectedTab == 1) {
                      _signaling.startVoiceCall(contact.id, callerName: contact.name);
                      bool _isMuted = false;
                      Navigator.push(context, MaterialPageRoute(
                        builder: (_) => StatefulBuilder(
                          builder: (ctx, setS) => CallScreen(
                            contactName: contact.name,
                            isOutgoing: true,
                            isMuted: _isMuted,
                            onMuteTap: () { setS(() => _isMuted = !_isMuted); _signaling.setMicMuted(_isMuted); },
                            onHangUp: () { _signaling.endVoiceCall(); Navigator.pop(ctx); },
                          ),
                        ),
                      ));
                      return;
                    }
                    Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => ChatScreen(
                        contact: contact,
                        signaling: _signaling,
                        relayService: _relayService,
                        connectionNotifier: _connectionNotifier,
                        myId: _identity.peerId,
                        onProcessBundle: (peerId, bundle) async {
                          await _signalService.processPreKeyBundleFromMap(peerId, bundle);
                        },
                        
                        initialMessages: _messages[contact.id] ?? [],
                        messagesService: _messagesService,
                        newMessageNotifier: _newMessageNotifier,
                        onMessageSaved: (text, isSent) {
                          _messagesService.addMessage(contact.id, text, isSent);
                        },
                        onEncrypt: (text) async {
                          if (_signalService.isInitialized) {
                            try {
                              return await _signalService.encrypt(contact.id, text);
                            } catch (e) {
                              print('Encrypt error: $e');
                            }
                          }
                          return text;
                        },
                      ),
                    ),
                  );
                  },
                );
              },
            ),
          ),
        ],
      ),

      // FAB
      floatingActionButton: FloatingActionButton(
        onPressed: () => _openQR(context),
        backgroundColor: kAccent,
        foregroundColor: kBg,
        elevation: 0,
        shape: const RoundedRectangleBorder(borderRadius: BorderRadius.zero),
        child: const Icon(Icons.add),
      ),

      // Bottom nav
      bottomNavigationBar: Container(
        decoration: const BoxDecoration(
          border: Border(top: BorderSide(color: kBorder)),
          color: kBg,
        ),
        child: BottomNavigationBar(
          currentIndex: 0,
          onTap: (i) {
            final labels = ['Mail', 'Notes', 'Planner', 'Social'];
            showDialog(
              context: context,
              builder: (_) => AlertDialog(
                backgroundColor: const Color(0xFF111111),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
                title: Text('Unsync ${labels[i]}',
                  style: const TextStyle(color: Color(0xFFF0F0F0), fontWeight: FontWeight.w700)),
                content: Text('Your secure ${labels[i].toLowerCase()} service is coming soon.',
                  style: const TextStyle(color: Color(0xFF555555))),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('Got it', style: TextStyle(color: Color(0xFF00FF87))),
                  ),
                ],
              ),
            );
          },
          backgroundColor: kBg,
          selectedItemColor: kAccent,
          unselectedItemColor: kMuted,
          showSelectedLabels: true,
          showUnselectedLabels: true,
          selectedLabelStyle: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600),
          unselectedLabelStyle: const TextStyle(fontSize: 11),
          elevation: 0,
          type: BottomNavigationBarType.fixed,
          items: const [
            BottomNavigationBarItem(icon: Icon(Icons.email_outlined), activeIcon: Icon(Icons.email), label: 'Mail'),
            BottomNavigationBarItem(icon: Icon(Icons.note_outlined), activeIcon: Icon(Icons.note), label: 'Notes'),
            BottomNavigationBarItem(icon: Icon(Icons.calendar_today_outlined), activeIcon: Icon(Icons.calendar_today), label: 'Planner'),
            BottomNavigationBarItem(icon: Icon(Icons.people_outline), activeIcon: Icon(Icons.people), label: 'Social'),
          ],
        ),
      ),
    );
  }

  Widget _buildTab(String label, int index) {
    final selected = _selectedTab == index;
    return GestureDetector(
      onTap: () => setState(() => _selectedTab = index),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        decoration: BoxDecoration(
          color: selected ? kAccentDim : Colors.transparent,
          border: Border.all(color: selected ? kAccent : kBorder),
        ),
        child: Text(
          label,
          textAlign: TextAlign.center,
          style: TextStyle(
            color: selected ? kAccent : kMuted,
            fontSize: 12,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.5,
          ),
        ),
      ),
    );
  }

  void _openQR(BuildContext context) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => QRScreen(
          peerId: _identity.peerId ?? '',
          displayName: _identity.displayName ?? 'Unknown',
          onContactScanned: (peerId, name) async {
            await _contactsService.addContact(peerId, name);
            if (mounted) setState(() {
              _realContacts = _contactsService.contacts.toList();
            });
            // connect on demand when message is sent
          },
        ),
      ),
    );
  }

  void _showSettings(BuildContext context) {
    final controller = TextEditingController(text: _identity.displayName ?? '');
    showModalBottomSheet(
      context: context,
      backgroundColor: kSurface,
      isScrollControlled: true,
      builder: (_) => _SettingsSheet(controller: controller, identity: _identity),
    );
  }



  void _showContactOptions(BuildContext context, Contact contact) {
    showModalBottomSheet(
      context: context,
      backgroundColor: kSurface,
      builder: (_) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: const Icon(Icons.delete_outline, color: Colors.redAccent),
            title: const Text('Clear chat history', style: TextStyle(color: kText)),
            onTap: () async {
              Navigator.pop(context);
              await _messagesService.clearMessages(contact.id);
              if (mounted) setState(() {
                _messages[contact.id] = [];
              });
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Chat history cleared')),
              );
            },
          ),
          ListTile(
            leading: const Icon(Icons.person_remove_outlined, color: Colors.redAccent),
            title: const Text('Remove contact', style: TextStyle(color: kText)),
            onTap: () async {
              Navigator.pop(context);
              await _contactsService.removeContact(contact.id);
              _signaling.disconnect();
              await Future.delayed(const Duration(milliseconds: 500));
              _connect();
              if (mounted) setState(() {
                _realContacts = _contactsService.contacts.toList();
              });
            },
          ),
          const SizedBox(height: 16),
        ],
      ),
    );
  }

  void _showAddContact(BuildContext context) {
    showModalBottomSheet(
      context: context,
      backgroundColor: kSurface,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.zero),
      builder: (_) => const _AddContactSheet(),
    );
  }
}

// ── CONTACT TILE ──────────────────────────────────────────────────────────────
class _ContactTile extends StatelessWidget {
  final Contact contact;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  const _ContactTile({required this.contact, required this.onTap, this.onLongPress});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      onLongPress: onLongPress,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Row(
          children: [
            // Avatar
            Stack(
              children: [
                Container(
                  width: 46, height: 46,
                  decoration: BoxDecoration(
                    color: kAccentDim,
                    border: Border.all(color: kBorder),
                    shape: BoxShape.circle,
                  ),
                  child: Center(
                    child: Text(
                      contact.initials,
                      style: const TextStyle(
                        color: kAccent, fontSize: 16,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ),
                if (contact.online)
                  Positioned(
                    right: 0, bottom: 0,
                    child: Container(
                      width: 12, height: 12,
                      decoration: BoxDecoration(
                        color: kAccent,
                        shape: BoxShape.circle,
                        border: Border.all(color: kBg, width: 2),
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(width: 14),

            // Name + last message
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    contact.name,
                    style: const TextStyle(
                      color: kText, fontSize: 15,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    contact.lastMessage,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: kMuted, fontSize: 13),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),

            // Time + unread
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  contact.time,
                  style: TextStyle(
                    color: contact.unread > 0 ? kAccent : kMuted,
                    fontSize: 11,
                  ),
                ),
                const SizedBox(height: 4),
                if (contact.unread > 0)
                  Container(
                    width: 20, height: 20,
                    decoration: const BoxDecoration(
                      color: kAccent,
                      shape: BoxShape.circle,
                    ),
                    child: Center(
                      child: Text(
                        '${contact.unread}',
                        style: const TextStyle(
                          color: kBg, fontSize: 11,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// ── ADD CONTACT SHEET ─────────────────────────────────────────────────────────
class _AddContactSheet extends StatelessWidget {
  const _AddContactSheet();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Add Contact',
            style: TextStyle(color: kText, fontSize: 18, fontWeight: FontWeight.w700)),
          const SizedBox(height: 6),
          const Text('No typing required. Just tap.',
            style: TextStyle(color: kMuted, fontSize: 13)),
          const SizedBox(height: 24),
          _addOption(Icons.nfc, 'NFC Tap', 'Tap phones together', true),
          const SizedBox(height: 12),
          _addOption(Icons.qr_code, 'Scan QR Code', 'Scan their Unsync QR', false),
          const SizedBox(height: 12),
          _addOption(Icons.link, 'Invite Link', 'Share a one-time link', false),
          const SizedBox(height: 12),
          _addOption(Icons.bluetooth, 'Nearby', 'Find people around you', false),
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  Widget _addOption(IconData icon, String title, String subtitle, bool primary) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: primary ? kAccentDim : Colors.transparent,
        border: Border.all(color: primary ? kAccent : kBorder),
      ),
      child: Row(
        children: [
          Icon(icon, color: primary ? kAccent : kMuted, size: 22),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                  style: TextStyle(
                    color: primary ? kAccent : kText,
                    fontSize: 14, fontWeight: FontWeight.w600,
                  )),
                Text(subtitle,
                  style: const TextStyle(color: kMuted, fontSize: 12)),
              ],
            ),
          ),
          Icon(Icons.chevron_right, color: primary ? kAccent : kMuted, size: 18),
        ],
      ),
    );
  }
}

// ── CHAT SCREEN ───────────────────────────────────────────────────────────────
class ChatScreen extends StatefulWidget {
  final Contact contact;
  final SignalingService? signaling;
  final RelayService? relayService;
  final ValueNotifier<bool> connectionNotifier;
  final String? myId;
  final Future<void> Function(String peerId, Map<String, dynamic> bundle)? onProcessBundle;
  final List<StoredMessage> initialMessages;
  final Function(String text, bool isSent)? onMessageSaved;
  final MessagesService? messagesService;
  final ValueNotifier<String>? newMessageNotifier;
  final Future<String> Function(String)? onEncrypt;
  const ChatScreen({super.key, required this.contact, this.signaling, this.relayService, required this.connectionNotifier, this.myId, this.onProcessBundle, this.initialMessages = const [], this.onMessageSaved, this.messagesService, this.newMessageNotifier, this.onEncrypt});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _controller = TextEditingController();
  final _scrollController = ScrollController();
  late List<Message> _messages;
  bool _showE2ee = true;
  @override
  void initState() {
    super.initState();
    _messages = widget.initialMessages.map((m) => Message(
      text: m.text,
      isSent: m.isSent,
      time: m.time,
    )).toList();
    // Load persisted messages
    widget.messagesService?.getMessages(widget.contact.id).then((stored) {
      if (mounted && stored.isNotEmpty) setState(() {
        _messages = stored.map((m) => Message(
          text: m.text,
          isSent: m.isSent,
          time: m.time,
        )).toList();
      });
    });
    // Listen for new messages from ContactsScreen
    widget.newMessageNotifier?.addListener(() {
      if (widget.newMessageNotifier!.value.startsWith(widget.contact.id)) {
        widget.messagesService?.getMessages(widget.contact.id).then((stored) {
          if (mounted) setState(() {
            _messages = stored.map((m) => Message(
              text: m.text,
              isSent: m.isSent,
              time: m.time,
            )).toList();
          });
        });
      }
    });
  }

  Future<void> _sendMessage() async {
    final text = _controller.text.trim();
    if (text.isEmpty) return;
    // Encrypt before sending
    String payload = text;
    if (widget.onEncrypt != null) {
      payload = await widget.onEncrypt!(text);
    }
    if (widget.signaling?.isPeerConnected(widget.contact.id) ?? false) {
      widget.signaling?.sendMessage(widget.contact.id, payload);
    } else {
      // peer offline — store to relay
      widget.relayService?.storeMessage(
        widget.contact.id,
        widget.myId ?? 'unknown',
        payload,
      );
      print('Relay: stored message for offline peer ${widget.contact.id}');
    }
    widget.onMessageSaved?.call(text, true);
    setState(() {
      _messages.add(Message(
        text: text,
        isSent: true,
        time: _currentTime(),
      ));
      _controller.clear();
    });
    Future.delayed(const Duration(milliseconds: 100), () {
      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOut,
      );
    });
  }

  String _currentTime() {
    final now = DateTime.now();
    return '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';
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
                    child: Text(
                      widget.contact.initials,
                      style: const TextStyle(
                        color: kAccent, fontSize: 14,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ),
                if (widget.contact.online)
                  Positioned(
                    right: 0, bottom: 0,
                    child: Container(
                      width: 10, height: 10,
                      decoration: BoxDecoration(
                        color: kAccent,
                        shape: BoxShape.circle,
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
                  style: const TextStyle(
                    color: kText, fontSize: 15,
                    fontWeight: FontWeight.w600,
                  )),
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
              await widget.signaling?.startVoiceCall(widget.contact.id, callerName: widget.contact.name);
              if (context.mounted) {
                bool _isMuted = false;
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => StatefulBuilder(
                      builder: (ctx, setS) => CallScreen(
                        contactName: widget.contact.name,
                        isOutgoing: true,
                        isMuted: _isMuted,
                        onMuteTap: () {
                          setS(() => _isMuted = !_isMuted);
                          widget.signaling?.setMicMuted(_isMuted);
                        },
                        onHangUp: () {
                          widget.signaling?.endVoiceCall();
                          Navigator.pop(ctx);
                        },
                      ),
                    ),
                  ),
                );
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
          // E2EE banner
          if (_showE2ee)
            GestureDetector(
              onTap: () => setState(() => _showE2ee = false),
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                color: kAccentDim,
                child: Row(
                  children: [
                    const Icon(Icons.lock_outline, color: kAccent, size: 14),
                    const SizedBox(width: 8),
                    const Expanded(
                      child: Text(
                        'Messages are end-to-end encrypted. Server never sees them.',
                        style: TextStyle(color: kAccent, fontSize: 11),
                      ),
                    ),
                    const Icon(Icons.close, color: kAccent, size: 14),
                  ],
                ),
              ),
            ),

          // Messages
          Expanded(
            child: ListView.builder(
              controller: _scrollController,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              itemCount: _messages.length,
              itemBuilder: (context, index) {
                final msg = _messages[index];
                return _MessageBubble(message: msg);
              },
            ),
          ),

          // Input bar
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
                        contentPadding: EdgeInsets.symmetric(horizontal: 14, vertical: 10),
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

// ── MESSAGE BUBBLE ────────────────────────────────────────────────────────────
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
                      ? const Color(0xFF00CC6A).withOpacity(0.2)
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
                  color: message.isSent ? const Color(0xFFB3FFD9) : kText,
                  fontSize: 14,
                  height: 1.5,
                ),
              ),
            ),
            const SizedBox(height: 3),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  message.time,
                  style: const TextStyle(color: kMuted, fontSize: 10),
                ),
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

// ── CALL SCREEN ───────────────────────────────────────────────────────────────
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
    await _identity.initialize();

    if (!mounted) return;

    if (_identity.isSetup) {
      // Check biometric gate
      final bioEnabled = await BiometricService.isEnabled();
      final bioAvailable = await BiometricService.isAvailable();
      if (bioEnabled && bioAvailable) {
        if (mounted) {
          Navigator.pushReplacement(
            context,
            MaterialPageRoute(
              builder: (_) => const BiometricScreen(
                destination: ContactsScreen(),
              ),
            ),
          );
        }
        return;
      }
      if (mounted) {
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(builder: (_) => const ContactsScreen()),
        );
      }
    } else {
      // New user — show setup
      if (mounted) {
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(
            builder: (newContext) => SetupScreen(
              onComplete: () {
                Navigator.of(newContext).pushAndRemoveUntil(
                  MaterialPageRoute(builder: (_) => const ContactsScreen()),
                  (route) => false,
                );
              },
            ),
          ),
        );
      }
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
              width: 12, height: 12,
              decoration: const BoxDecoration(
                color: kAccent,
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(height: 16),
            const Text('unsync',
              style: TextStyle(
                color: kText,
                fontSize: 28,
                fontWeight: FontWeight.w700,
                letterSpacing: -1,
              )),
            const SizedBox(height: 32),
            const SizedBox(
              width: 20, height: 20,
              child: CircularProgressIndicator(
                color: kAccent, strokeWidth: 2,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SettingsSheet extends StatefulWidget {
  final TextEditingController controller;
  final dynamic identity;
  const _SettingsSheet({required this.controller, required this.identity});

  @override
  State<_SettingsSheet> createState() => _SettingsSheetState();
}

class _SettingsSheetState extends State<_SettingsSheet> {
  bool _bioAvailable = false;
  bool _bioEnabled = false;

  @override
  void initState() {
    super.initState();
    _loadBio();
  }

  Future<void> _loadBio() async {
    final avail = await BiometricService.isAvailable();
    final enabled = await BiometricService.isEnabled();
    if (mounted) setState(() { _bioAvailable = avail; _bioEnabled = enabled; });
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        left: 24, right: 24, top: 24,
        bottom: MediaQuery.of(context).viewInsets.bottom + 24,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Settings', style: TextStyle(color: kText, fontSize: 18, fontWeight: FontWeight.bold)),
          const SizedBox(height: 16),
          const Text('Display name', style: TextStyle(color: kMuted, fontSize: 12)),
          const SizedBox(height: 8),
          TextField(
            controller: widget.controller,
            style: const TextStyle(color: kText),
            decoration: const InputDecoration(
              enabledBorder: OutlineInputBorder(borderSide: BorderSide(color: kBorder)),
              focusedBorder: OutlineInputBorder(borderSide: BorderSide(color: kAccent)),
            ),
          ),
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: TextButton(
              onPressed: () async {
                final name = widget.controller.text.trim();
                if (name.isNotEmpty) {
                  await widget.identity.setDisplayName(name);
                  if (context.mounted) {
                    Navigator.pop(context);
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Display name updated!')),
                    );
                  }
                }
              },
              style: TextButton.styleFrom(backgroundColor: kAccent),
              child: const Text('Save', style: TextStyle(color: kBg)),
            ),
          ),
          if (_bioAvailable) ...[
            const SizedBox(height: 8),
            const Divider(color: kBorder),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Biometric lock', style: TextStyle(color: kText, fontSize: 14)),
                    Text('Require fingerprint on open', style: TextStyle(color: kMuted, fontSize: 11)),
                  ],
                ),
                Switch(
                  value: _bioEnabled,
                  activeThumbColor: kAccent,
                  onChanged: (val) async {
                    if (val) {
                      Navigator.pop(context);
                      await Future.delayed(const Duration(milliseconds: 300));
                      final ok = await BiometricService.authenticate();
                      if (!ok) return;
                    }
                    await BiometricService.setEnabled(val);
                    if (mounted) setState(() => _bioEnabled = val);
                  },
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}
