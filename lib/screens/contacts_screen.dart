import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart' as signal;
import '../theme.dart';
import '../models/contact.dart';
import '../services/identity_service.dart';
import '../services/signaling_service.dart';
import '../services/relay_service.dart';
import '../services/contacts_service.dart';
import '../services/messages_service.dart';
import '../services/signal_service.dart';
import '../services/foreground_service.dart';
import '../services/fcm_service.dart';
import '../services/call_notification_service.dart';
import '../services/message_notification_service.dart';
import '../services/biometric_service.dart';
import '../services/profile_photo_service.dart';
import 'qr_screen.dart';
import 'call_screen.dart';
import 'incoming_call_screen.dart';
import 'chat_screen.dart';

class ContactsScreen extends StatefulWidget {
  const ContactsScreen({super.key});

  @override
  State<ContactsScreen> createState() => _ContactsScreenState();
}

class _ContactsScreenState extends State<ContactsScreen> {
  int _selectedTab = 0;
  final _signaling       = SignalingService();
  final _identity        = IdentityService();
  final _contactsService = ContactsService();
  final _messagesService = MessagesService();
  final _signalService   = SignalService();
  final _relayService    = RelayService();
  final _profilePhotoService = ProfilePhotoService();

  bool _connected = false;
  List<SavedContact> _realContacts = [];
  String? _profilePhotoPath;
  Map<String, String> _contactPhotoPaths = {};
  final _newMessageNotifier  = ValueNotifier<String>('');
  final _connectionNotifier  = ValueNotifier<bool>(false);
  final _callAnsweredNotifier = ValueNotifier<bool>(false);
  final _remoteStreamNotifier = ValueNotifier<dynamic>(null);
  String? _pendingCallPeerId;
  String? _openChatPeerId;
  Route<void>? _activeCallRoute;
  bool _incomingCallRouteOpen = false;

  @override
  void initState() {
    super.initState();
    _loadProfilePhoto();
    _connect();
  }

  Future<void> _loadProfilePhoto() async {
    final path = await _profilePhotoService.loadProfilePhotoPath();
    if (mounted) setState(() => _profilePhotoPath = path);
  }

  Future<void> _reloadContacts() async {
    await _contactsService.initialize();
    final contacts = _contactsService.contacts.toList();
    final photoPaths = <String, String>{};
    for (final contact in contacts) {
      final path = await _contactsService.getContactPhotoPath(contact.peerId);
      if (path != null) photoPaths[contact.peerId] = path;
    }
    if (mounted) {
      setState(() {
        _realContacts = contacts;
        _contactPhotoPaths = photoPaths;
      });
    }
  }

  void _queueIncomingCallRoute(String callerId) {
    _pendingCallPeerId = callerId;
    _drainPendingCallRoute();
  }

  void _drainPendingCallRoute() {
    if (!mounted) return;
    if (_incomingCallRouteOpen) return;
    final callerId = _pendingCallPeerId;
    if (callerId == null) return;

    _pendingCallPeerId = null;
    _incomingCallRouteOpen = true;

    final fallbackName = CallNotificationService.lastCallerName ?? callerId;
    final saved = _realContacts.firstWhere(
      (c) => c.peerId == callerId,
      orElse: () => SavedContact(
        peerId: callerId,
        displayName: fallbackName,
        addedAt: DateTime.now(),
      ),
    );

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
              final route = _createCallRoute(saved.displayName, false);
              Navigator.pushReplacement(
                context,
                route,
              ).whenComplete(() => _clearCallRoute(route));
            }
          },
        ),
      ),
    ).whenComplete(() {
      _incomingCallRouteOpen = false;
      if (_pendingCallPeerId != null) {
        _drainPendingCallRoute();
      }
    });
  }

  Future<void> _connect() async {
    try {
      ForegroundServiceManager.init();
      await _identity.initialize();
      await Future.microtask(() => _signalService.initialize());
      await _reloadContacts();

      final id = _identity.peerId ?? DateTime.now().millisecondsSinceEpoch.toString();

      await CallNotificationService.initialize();
      await MessageNotificationService.initialize();

      // ── notification tap handlers ──────────────────────────────────────────
      MessageNotificationService.onNotificationTapped = (peerId) async {
        if (_openChatPeerId == peerId) return;
        await Future.delayed(const Duration(seconds: 2));
        await _reloadContacts();
        final saved = _realContacts.firstWhere(
          (c) => c.peerId == peerId,
          orElse: () => SavedContact(peerId: peerId, displayName: peerId, addedAt: DateTime.now()),
        );
        if (!mounted) return;
        final contact = Contact(
          id: saved.peerId,
          name: saved.displayName,
          initials: saved.displayName.substring(0, 1).toUpperCase(),
          lastMessage: '', time: '', online: true,
          photoPath: _contactPhotoPaths[saved.peerId],
        );
        _openChatPeerId = saved.peerId;
        Navigator.push(context, MaterialPageRoute(
          builder: (_) => ChatScreen(
            contact: contact,
            signaling: _signaling,
            relayService: _relayService,
            connectionNotifier: _connectionNotifier,
            myId: _identity.peerId,
            myName: _identity.displayName,
            onProcessBundle: (pid, bundle) async =>
                await _signalService.processPreKeyBundleFromMap(pid, bundle),
            onInitializeSession: (pid, bundle) async =>
                await _signalService.initializeSession(pid, bundle),
            messagesService: _messagesService,
            newMessageNotifier: _newMessageNotifier,
            onMessageSaved: (text, isSent) =>
                _messagesService.addMessage(contact.id, text, isSent),
            onEncrypt: (text) async {
              if (_signalService.isInitialized) {
                return await _signalService.encrypt(contact.id, text);
              }
              throw SignalSessionMissingException(contact.id);
            },
            callAnsweredNotifier: _callAnsweredNotifier,
            remoteStreamNotifier: _remoteStreamNotifier,
          ),
        )).whenComplete(() => _openChatPeerId = null);
      };

      CallNotificationService.onNotificationTapped = (callerId) {
        _queueIncomingCallRoute(callerId);
      };

      // ── FCM ────────────────────────────────────────────────────────────────
      final fcmToken = await FCMService.initialize();

      // ── relay ──────────────────────────────────────────────────────────────
      await _relayService.connect(id, fcmToken: fcmToken);

      Future.delayed(const Duration(seconds: 2), () async {
        try {
          final bundle = await _signalService.buildPreKeyBundle();
          _relayService.uploadBundle(id, {
            'registrationId':      bundle.getRegistrationId(),
            'identityKey':         base64Encode(bundle.getIdentityKey().serialize()),
            'preKeyId':            bundle.getPreKeyId(),
            'preKey':              base64Encode(bundle.getPreKey()!.serialize()),
            'signedPreKeyId':      bundle.getSignedPreKeyId(),
            'signedPreKey':        base64Encode(bundle.getSignedPreKey()!.serialize()),
            'signedPreKeySignature': base64Encode(bundle.getSignedPreKeySignature() ?? Uint8List(0)),
          });
        } catch (e) { print('Bundle upload failed: \$e'); }
      });

      _relayService.onQueuedMessage = (from, payload) async {
        String text = payload;
        if (_signalService.isInitialized) {
          try {
            if (!_signalService.hasSession(from)) {
              final senderBundle = await _relayService.fetchBundle(from);
              if (senderBundle != null) {
                await _signalService.processPreKeyBundleFromMap(from, senderBundle);
              }
            }
            text = await _signalService.decrypt(from, payload);
          } catch (e) { print('Relay decrypt error: \$e'); }
        }
        await _messagesService.addMessage(from, text, false);
        print(
          'Relay queued message from=$from notifier=$from:${DateTime.now().millisecondsSinceEpoch}',
        );
        _newMessageNotifier.value = '${from}:${DateTime.now().millisecondsSinceEpoch}';
        MessageNotificationService.playMessageSound();
        final senderName = _realContacts.firstWhere(
          (c) => c.peerId == from,
          orElse: () => SavedContact(peerId: from, displayName: from, addedAt: DateTime.now()),
        ).displayName;
        MessageNotificationService.showMessageNotification(senderName, text, peerId: from);
      };

      // ── signaling ──────────────────────────────────────────────────────────
      _signaling.onConnectionStateChanged = (connected) {
        _connectionNotifier.value = connected;
        if (mounted) setState(() => _connected = connected);
      };

      _signaling.onPeerOffline = (peerId) {
        _connectionNotifier.value = false;
        if (mounted) setState(() => _connected = false);
      };

      _signaling.onIncomingCall = (peerId) async {
        final saved = _realContacts.firstWhere(
          (c) => c.peerId == peerId,
          orElse: () => SavedContact(peerId: peerId, displayName: peerId, addedAt: DateTime.now()),
        );
        await CallNotificationService.showIncomingCall(saved.displayName, peerId);
        _queueIncomingCallRoute(peerId);
      };

      _signaling.onCallAnswered = () {
        _callAnsweredNotifier.value = true;
      };

      _signaling.onRemoteStream = (stream) {
        _remoteStreamNotifier.value = stream;
      };

      _signaling.onCallEnded = () {
        try { CallNotificationService.cancel(); } catch (_) {}
        _callAnsweredNotifier.value = false;
        _remoteStreamNotifier.value = null;
        _popActiveCallRoute();
      };

      // ── killed-state notification resume ───────────────────────────────────
      Future.microtask(() async {
        final initialCallerId = await CallNotificationService.getInitialCallerId();
        if (initialCallerId != null) {
          for (int i = 0; i < 30; i++) {
            await Future.delayed(const Duration(milliseconds: 500));
            if (_signaling.myId != null && _realContacts.isNotEmpty) break;
          }
          if (mounted) _queueIncomingCallRoute(initialCallerId);
        }

        final initialPeerId = await MessageNotificationService.getInitialPeerId();
        if (initialPeerId != null) {
          for (int i = 0; i < 30; i++) {
            await Future.delayed(const Duration(milliseconds: 500));
            if (_signaling.myId != null && _realContacts.isNotEmpty) break;
          }
          if (mounted) MessageNotificationService.onNotificationTapped?.call(initialPeerId);
        }

        final prefs = await SharedPreferences.getInstance();
        final pendingFromId = prefs.getString('pending_message_wake');
        if (pendingFromId != null && pendingFromId.isNotEmpty) {
          await prefs.remove('pending_message_wake');
          await MessageNotificationService.cancel();
          for (int i = 0; i < 30; i++) {
            await Future.delayed(const Duration(milliseconds: 500));
            if (_signaling.myId != null && _realContacts.isNotEmpty) break;
          }
          if (mounted) MessageNotificationService.onNotificationTapped?.call(pendingFromId);
        }
      });

      // ── message handling ───────────────────────────────────────────────────
      _signaling.onMessageReceived = (peerId, msg) async {
        try {
          final parsed = jsonDecode(msg);
          if (parsed['type'] == 'handshake') {
            final name = parsed['name'] as String;
            final hid  = parsed['peerId'] as String;
            await _contactsService.addContact(hid, name);
            final photoBase64 = parsed['photoBase64'];
            if (photoBase64 is String && photoBase64.isNotEmpty) {
              if (photoBase64.length > 150 * 1024) {
                print('Ignoring oversized profile photo');
              } else {
                try {
                  await _contactsService.saveContactPhoto(hid, base64Decode(photoBase64));
                } catch (e) {
                  print('Failed to save profile photo: $e');
                }
              }
            }
            await _reloadContacts();
            if (parsed['signalBundle'] != null) {
              final b = parsed['signalBundle'];
              try {
                final bundle = signal.PreKeyBundle(
                  b['registrationId'], 1,
                  b['preKeyId'],
                  signal.Curve.decodePoint(base64Decode(b['preKey'] as String), 0),
                  b['signedPreKeyId'],
                  signal.Curve.decodePoint(base64Decode(b['signedPreKey'] as String), 0),
                  base64Decode(b['signedPreKeySignature'] as String),
                  signal.IdentityKey.fromBytes(base64Decode(b['identityKey'] as String), 0),
                );
                await _signalService.processPreKeyBundle(hid, bundle);
              } catch (e) { print('Signal bundle error: \$e'); }
            }
            return;
          }
        } catch (_) {}

        String plaintext = msg;
        if (_signalService.isInitialized) {
          try {
            plaintext = await _signalService.decrypt(peerId, msg);
          } catch (e) {
            print('Decrypt error: \$e');
          }
        }
        _messagesService.addMessage(peerId, plaintext, false).then((_) {
          if (mounted) {
            print(
              'P2P message peerId=$peerId notifier=$peerId:${DateTime.now().millisecondsSinceEpoch}',
            );
            _newMessageNotifier.value = '${peerId}:${DateTime.now().millisecondsSinceEpoch}';
            setState(() {
              MessageNotificationService.playMessageSound();
              final senderName = _realContacts.firstWhere(
                (c) => c.peerId == peerId,
                orElse: () => SavedContact(
                  peerId: peerId,
                  displayName: peerId,
                  addedAt: DateTime.now(),
                ),
              ).displayName;
              MessageNotificationService.showMessageNotification(
                senderName,
                plaintext,
                peerId: peerId,
              );
            });
          }
        });
      };

      _signaling.onPeerConnected = (peerId) async {
        _connectionNotifier.value = true;
        final myName = _identity.displayName ?? 'Unknown';
        final myId2  = _identity.peerId ?? '';
        final bundle = await _signalService.buildPreKeyBundle();
        final handshake = <String, dynamic>{
          'type': 'handshake',
          'name': myName,
          'peerId': myId2,
          'signalBundle': {
            'registrationId':      bundle.getRegistrationId(),
            'identityKey':         base64Encode(bundle.getIdentityKey().serialize()),
            'preKeyId':            bundle.getPreKeyId(),
            'preKey':              base64Encode(bundle.getPreKey()!.serialize()),
            'signedPreKeyId':      bundle.getSignedPreKeyId(),
            'signedPreKey':        base64Encode(bundle.getSignedPreKey()!.serialize()),
            'signedPreKeySignature': base64Encode(bundle.getSignedPreKeySignature()!),
          }
        };
        final profilePhotoPath = _profilePhotoPath;
        if (profilePhotoPath != null) {
          final file = File(profilePhotoPath);
          if (await file.exists()) {
            handshake['photoBase64'] = base64Encode(await file.readAsBytes());
          }
        }
        _signaling.sendMessage(peerId, jsonEncode(handshake));
      };

      await _signaling.connect(id, fcmToken: fcmToken, handle: _identity.displayName);
      ForegroundServiceManager.start();

      FirebaseMessaging.onMessage.listen((message) {
        if (!_relayService.isConnected) {
          _relayService.connect(id, fcmToken: fcmToken);
        }
      });

    } catch (e, stack) {
      print('Connect error: \$e');
      print(stack);
    }
  }

  // ── helpers ────────────────────────────────────────────────────────────────

  Widget _buildCallScreen(String contactName, bool isOutgoing) {
    bool isMuted = false;
    return StatefulBuilder(
      builder: (ctx, setS) => CallScreen(
        contactName: contactName,
        isOutgoing: isOutgoing,
        isMuted: isMuted,
        onMuteTap: () {
          setS(() => isMuted = !isMuted);
          _signaling.setMicMuted(isMuted);
        },
        onHangUp: () => _signaling.endVoiceCall(),
        callAnsweredNotifier: _callAnsweredNotifier,
        remoteStreamNotifier: _remoteStreamNotifier,
      ),
    );
  }

  MaterialPageRoute<void> _createCallRoute(String contactName, bool isOutgoing) {
    final route = MaterialPageRoute<void>(
      settings: const RouteSettings(name: 'call'),
      builder: (_) => _buildCallScreen(contactName, isOutgoing),
    );
    _activeCallRoute = route;
    return route;
  }

  void _clearCallRoute(Route<void> route) {
    if (_activeCallRoute == route) _activeCallRoute = null;
  }

  void _popActiveCallRoute() {
    final route = _activeCallRoute;
    if (!mounted || route == null || !route.isCurrent) return;
    Navigator.of(context).pop();
    _activeCallRoute = null;
  }

  void _openQR(BuildContext context) {
    Navigator.push(context, MaterialPageRoute(
      builder: (_) => QRScreen(
        peerId: _identity.peerId ?? '',
        displayName: _identity.displayName ?? 'Unknown',
        onContactScanned: (peerId, name) async {
          await _contactsService.addContact(peerId, name);
          await _reloadContacts();
        },
      ),
    ));
  }

  void _showSettings(BuildContext context) {
    final controller = TextEditingController(text: _identity.displayName ?? '');
    showModalBottomSheet(
      context: context,
      backgroundColor: kSurface,
      isScrollControlled: true,
      builder: (_) => _SettingsSheet(
        controller: controller,
        identity: _identity,
        profilePhotoPath: _profilePhotoPath,
        onProfilePhotoChanged: (path) {
          if (mounted) setState(() => _profilePhotoPath = path);
        },
      ),
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
              await _reloadContacts();
            },
          ),
          const SizedBox(height: 16),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _signaling.dispose();
    _relayService.dispose();
    _newMessageNotifier.dispose();
    _connectionNotifier.dispose();
    _callAnsweredNotifier.dispose();
    _remoteStreamNotifier.dispose();
    super.dispose();
  }

  // ── build ──────────────────────────────────────────────────────────────────

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
                const Text('unsync',
                  style: TextStyle(color: kText, fontSize: 20,
                    fontWeight: FontWeight.w700, letterSpacing: -0.5)),
                Text(
                  _connected ? 'mesh connected' : 'connecting...',
                  style: TextStyle(color: _connected ? kAccent : kMuted, fontSize: 10),
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
                child: const Text('✅ mesh connected — tap to see your ID',
                  style: TextStyle(color: kAccent, fontSize: 11)),
              ),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Container(
              decoration: BoxDecoration(color: kSurface, border: Border.all(color: kBorder)),
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
          Expanded(
            child: ListView.separated(
              itemCount: _realContacts.length,
              separatorBuilder: (_, _) => Container(height: 1, color: kBorder),
              itemBuilder: (context, index) {
                if (index >= _realContacts.length) return const SizedBox.shrink();
                final c = _realContacts[index];
                final contact = Contact(
                  id: c.peerId,
                  name: c.displayName,
                  initials: c.displayName.substring(0, 1).toUpperCase(),
                  lastMessage: _selectedTab == 0 ? 'Tap to chat' : 'Tap to call',
                  time: '', online: true,
                  photoPath: _contactPhotoPaths[c.peerId],
                );
                return _ContactTile(
                  contact: contact,
                  onLongPress: () => _showContactOptions(context, contact),
                  onTap: () {
                    if (_selectedTab == 1) {
                      _signaling.startVoiceCall(contact.id, callerName: _identity.displayName ?? '');
                      final route = _createCallRoute(contact.name, true);
                      Navigator.push(context, route)
                          .whenComplete(() => _clearCallRoute(route));
                      return;
                    }
                    _openChatPeerId = contact.id;
                    Navigator.push(context, MaterialPageRoute(
                      builder: (_) => ChatScreen(
                        contact: contact,
                        signaling: _signaling,
                        relayService: _relayService,
                        connectionNotifier: _connectionNotifier,
                        myId: _identity.peerId,
                        myName: _identity.displayName,
                        onProcessBundle: (pid, bundle) async =>
                            await _signalService.processPreKeyBundleFromMap(pid, bundle),
                        onInitializeSession: (pid, bundle) async =>
                            await _signalService.initializeSession(pid, bundle),
                        messagesService: _messagesService,
                        newMessageNotifier: _newMessageNotifier,
                        onMessageSaved: (text, isSent) =>
                            _messagesService.addMessage(contact.id, text, isSent),
                        onEncrypt: (text) async {
                          if (_signalService.isInitialized) {
                            return await _signalService.encrypt(contact.id, text);
                          }
                          throw SignalSessionMissingException(contact.id);
                        },
                        callAnsweredNotifier: _callAnsweredNotifier,
                        remoteStreamNotifier: _remoteStreamNotifier,
                      ),
                    )).whenComplete(() => _openChatPeerId = null);
                  },
                );
              },
            ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _openQR(context),
        backgroundColor: kAccent,
        foregroundColor: kBg,
        elevation: 0,
        shape: const RoundedRectangleBorder(borderRadius: BorderRadius.zero),
        child: const Icon(Icons.add),
      ),
    );
  }

  Widget _buildTab(String label, int index) {
    final selected = _selectedTab == index;
    return GestureDetector(
      onTap: () => setState(() => _selectedTab = index),
      child: Container(
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
            fontSize: 12, fontWeight: FontWeight.w600, letterSpacing: 0.5,
          ),
        ),
      ),
    );
  }
}

// ── Contact Tile ──────────────────────────────────────────────────────────────
class _ContactTile extends StatelessWidget {
  final Contact contact;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  const _ContactTile({required this.contact, required this.onTap, this.onLongPress});

  @override
  Widget build(BuildContext context) {
    final photoFile = contact.photoPath == null ? null : File(contact.photoPath!);
    final hasPhoto = photoFile != null && photoFile.existsSync();

    return InkWell(
      onTap: onTap,
      onLongPress: onLongPress,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Row(
          children: [
            Stack(
              children: [
                if (hasPhoto)
                  CircleAvatar(
                    radius: 23,
                    backgroundImage: FileImage(photoFile),
                    backgroundColor: kAccentDim,
                  )
                else
                  Container(
                    width: 46, height: 46,
                    decoration: BoxDecoration(
                      color: kAccentDim,
                      border: Border.all(color: kBorder),
                      shape: BoxShape.circle,
                    ),
                    child: Center(
                      child: Text(contact.initials,
                        style: const TextStyle(color: kAccent, fontSize: 16,
                          fontWeight: FontWeight.w700)),
                    ),
                  ),
                if (contact.online)
                  Positioned(
                    right: 0, bottom: 0,
                    child: Container(
                      width: 12, height: 12,
                      decoration: BoxDecoration(
                        color: kAccent, shape: BoxShape.circle,
                        border: Border.all(color: kBg, width: 2),
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(contact.name,
                    style: const TextStyle(color: kText, fontSize: 15,
                      fontWeight: FontWeight.w600)),
                  const SizedBox(height: 3),
                  Text(contact.lastMessage,
                    maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: kMuted, fontSize: 13)),
                ],
              ),
            ),
            const SizedBox(width: 12),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(contact.time,
                  style: TextStyle(
                    color: contact.unread > 0 ? kAccent : kMuted,
                    fontSize: 11,
                  )),
                const SizedBox(height: 4),
                if (contact.unread > 0)
                  Container(
                    width: 20, height: 20,
                    decoration: const BoxDecoration(color: kAccent, shape: BoxShape.circle),
                    child: Center(
                      child: Text('\${contact.unread}',
                        style: const TextStyle(color: kBg, fontSize: 11,
                          fontWeight: FontWeight.w700)),
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

// ── Settings Sheet ────────────────────────────────────────────────────────────
class _SettingsSheet extends StatefulWidget {
  final TextEditingController controller;
  final dynamic identity;
  final String? profilePhotoPath;
  final ValueChanged<String?> onProfilePhotoChanged;
  const _SettingsSheet({
    required this.controller,
    required this.identity,
    required this.profilePhotoPath,
    required this.onProfilePhotoChanged,
  });

  @override
  State<_SettingsSheet> createState() => _SettingsSheetState();
}

class _SettingsSheetState extends State<_SettingsSheet> {
  final _profilePhotoService = ProfilePhotoService();
  bool _bioAvailable = false;
  bool _bioEnabled   = false;
  String? _profilePhotoPath;

  @override
  void initState() {
    super.initState();
    _profilePhotoPath = widget.profilePhotoPath;
    _loadBio();
  }

  Future<void> _loadBio() async {
    final avail   = await BiometricService.isAvailable();
    final enabled = await BiometricService.isEnabled();
    if (mounted) setState(() { _bioAvailable = avail; _bioEnabled = enabled; });
  }

  Future<void> _pickProfilePhoto() async {
    final path = await _profilePhotoService.pickAndSaveProfilePhoto();
    if (path == null) return;
    if (!mounted) return;
    setState(() => _profilePhotoPath = path);
    widget.onProfilePhotoChanged(path);
  }

  Widget _buildProfilePhoto() {
    final path = _profilePhotoPath;
    final displayName = (widget.identity.displayName as String?) ?? '';
    final initial = displayName.trim().isNotEmpty
        ? displayName.trim().substring(0, 1).toUpperCase()
        : '?';
    final hasPhoto = path != null && File(path).existsSync();

    return GestureDetector(
      onTap: _pickProfilePhoto,
      child: Column(
        children: [
          Container(
            width: 72,
            height: 72,
            decoration: BoxDecoration(
              color: kAccentDim,
              border: Border.all(color: kBorder),
              shape: BoxShape.circle,
              image: hasPhoto
                  ? DecorationImage(
                      image: FileImage(File(path)),
                      fit: BoxFit.cover,
                    )
                  : null,
            ),
            child: hasPhoto
                ? null
                : Center(
                    child: Text(
                      initial,
                      style: const TextStyle(
                        color: kAccent,
                        fontSize: 26,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
          ),
          const SizedBox(height: 8),
          const Text('Change photo', style: TextStyle(color: kAccent, fontSize: 12)),
        ],
      ),
    );
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
          const Text('Settings',
            style: TextStyle(color: kText, fontSize: 18, fontWeight: FontWeight.bold)),
          const SizedBox(height: 16),
          Center(child: _buildProfilePhoto()),
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
                    Text('Biometric lock',
                      style: TextStyle(color: kText, fontSize: 14)),
                    Text('Require fingerprint on open',
                      style: TextStyle(color: kMuted, fontSize: 11)),
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
