/// Controls when Mercury will introduce itself to a peer it does not know.
///
/// The identity handshake carries display name, Signal prekey bundle and full
/// profile photo. It used to be sent to anyone who opened a data channel, so
/// knowing a peer id was enough to harvest all three.
///
/// Saved contacts are always allowed. An unknown peer is only allowed while
/// the user is actively pairing — the QR screen is open, or closed recently
/// enough that a scan is still likely to be completing. Displaying your code
/// is the moment you are consenting to be introduced.
///
/// The grace period matters: the QR payload carries no Signal bundle, so each
/// side still learns the other's prekey bundle from the handshake, and the
/// scanner typically connects some time after the code leaves the screen.
class PairingWindowService {
  /// How long after the QR screen closes an unknown peer may still be
  /// introduced. Long enough to cover "scan the code, then open a chat",
  /// short enough that the window is not effectively always open.
  static const Duration grace = Duration(minutes: 5);

  /// Injectable clock so the window can be tested without waiting.
  static DateTime Function() now = DateTime.now;

  static bool _screenOpen = false;
  static DateTime? _closesAt;

  /// True while the user is pairing.
  static bool get isOpen {
    if (_screenOpen) return true;
    final closesAt = _closesAt;
    if (closesAt == null) return false;
    return now().isBefore(closesAt);
  }

  /// Call when the QR screen appears.
  static void open() {
    _screenOpen = true;
    _closesAt = null;
  }

  /// Call when the QR screen is dismissed. Starts the grace period.
  static void close() {
    if (!_screenOpen) return;
    _screenOpen = false;
    _closesAt = now().add(grace);
  }

  /// The single decision this service exists to answer.
  static bool mayIntroduceTo({required bool isSavedContact}) =>
      isSavedContact || isOpen;

  /// Test hook — clears all window state and restores the real clock.
  static void reset() {
    _screenOpen = false;
    _closesAt = null;
    now = DateTime.now;
  }
}
