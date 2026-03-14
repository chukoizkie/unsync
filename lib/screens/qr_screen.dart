import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'dart:convert';

const kBg = Color(0xFF0A0A0A);
const kSurface = Color(0xFF111111);
const kAccent = Color(0xFF00FF88);
const kAccentDim = Color(0xFF00FF8820);
const kText = Color(0xFFEEEEEE);
const kMuted = Color(0xFF666666);
const kBorder = Color(0xFF222222);

class QRScreen extends StatefulWidget {
  final String peerId;
  final String displayName;
  final void Function(String peerId, String name)? onContactScanned;

  const QRScreen({
    super.key,
    required this.peerId,
    required this.displayName,
    this.onContactScanned,
  });

  @override
  State<QRScreen> createState() => _QRScreenState();
}

class _QRScreenState extends State<QRScreen> with SingleTickerProviderStateMixin {
  late TabController _tabController;
  bool _scanned = false;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  String get _qrData => jsonEncode({
    'peerId': widget.peerId,
    'name': widget.displayName,
  });

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
        title: const Text('Add Contact', style: TextStyle(color: kText, fontSize: 16)),
        bottom: TabBar(
          controller: _tabController,
          indicatorColor: kAccent,
          labelColor: kAccent,
          unselectedLabelColor: kMuted,
          tabs: const [
            Tab(text: 'My QR Code'),
            Tab(text: 'Scan QR'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [
          _buildMyQR(),
          _buildScanner(),
        ],
      ),
    );
  }

  Widget _buildMyQR() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(16),
            ),
            child: QrImageView(
              data: _qrData,
              version: QrVersions.auto,
              size: 220,
              backgroundColor: Colors.white,
            ),
          ),
          const SizedBox(height: 24),
          Text(
            widget.displayName,
            style: const TextStyle(color: kText, fontSize: 20, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          GestureDetector(
            onTap: () {
              Clipboard.setData(ClipboardData(text: widget.peerId));
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Peer ID copied!')),
              );
            },
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              decoration: BoxDecoration(
                color: kSurface,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: kBorder),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    widget.peerId,
                    style: const TextStyle(color: kMuted, fontSize: 12, fontFamily: 'monospace'),
                  ),
                  const SizedBox(width: 8),
                  const Icon(Icons.copy, color: kMuted, size: 14),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          const Text(
            'Show this QR code to add you as a contact',
            style: TextStyle(color: kMuted, fontSize: 13),
          ),
        ],
      ),
    );
  }

  Widget _buildScanner() {
    return Column(
      children: [
        Expanded(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(16),
            child: MobileScanner(
              onDetect: (capture) {
                if (_scanned) return;
                final barcode = capture.barcodes.firstOrNull;
                if (barcode?.rawValue == null) return;
                try {
                  final data = jsonDecode(barcode!.rawValue!);
                  final peerId = data['peerId'] as String;
                  final name = data['name'] as String;
                  setState(() => _scanned = true);
                  widget.onContactScanned?.call(peerId, name);
                  Navigator.pop(context);
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('Connecting to $name...')),
                  );
                } catch (e) {
                  // not a valid unsync QR
                }
              },
            ),
          ),
        ),
        const Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'Point camera at another Unsync user\'s QR code',
            style: TextStyle(color: kMuted, fontSize: 13),
            textAlign: TextAlign.center,
          ),
        ),
      ],
    );
  }
}
