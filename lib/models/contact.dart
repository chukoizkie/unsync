class Contact {
  final String id;
  final String name;
  final String initials;
  final String lastMessage;
  final String time;
  final bool online;
  final int unread;
  final String? photoPath;

  const Contact({
    required this.id,
    required this.name,
    required this.initials,
    required this.lastMessage,
    required this.time,
    required this.online,
    this.unread = 0,
    this.photoPath,
  });
}
