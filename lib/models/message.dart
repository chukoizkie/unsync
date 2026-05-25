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
