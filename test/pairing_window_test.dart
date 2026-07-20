import 'package:flutter_test/flutter_test.dart';
import 'package:unsync/services/pairing_window_service.dart';

void main() {
  var clock = DateTime(2026, 1, 1, 12);

  setUp(() {
    PairingWindowService.reset();
    clock = DateTime(2026, 1, 1, 12);
    PairingWindowService.now = () => clock;
  });

  tearDown(PairingWindowService.reset);

  test('saved contacts are always introduced, window closed', () {
    expect(PairingWindowService.isOpen, isFalse);
    expect(
      PairingWindowService.mayIntroduceTo(isSavedContact: true),
      isTrue,
    );
  });

  test('unknown peers are refused while the window is closed', () {
    // The leak: any peer id that opened a data channel used to receive our
    // display name, prekey bundle and profile photo.
    expect(
      PairingWindowService.mayIntroduceTo(isSavedContact: false),
      isFalse,
    );
  });

  test('unknown peers are allowed while the QR screen is open', () {
    PairingWindowService.open();

    expect(PairingWindowService.isOpen, isTrue);
    expect(
      PairingWindowService.mayIntroduceTo(isSavedContact: false),
      isTrue,
    );
  });

  test('window stays open through the grace period after closing', () {
    PairingWindowService.open();
    PairingWindowService.close();

    // The QR payload carries no Signal bundle, so the scanner still needs a
    // handshake — and it typically connects after the code leaves the screen.
    clock = clock.add(PairingWindowService.grace - const Duration(minutes: 1));

    expect(
      PairingWindowService.mayIntroduceTo(isSavedContact: false),
      isTrue,
    );
  });

  test('window shuts once the grace period elapses', () {
    PairingWindowService.open();
    PairingWindowService.close();

    clock = clock.add(PairingWindowService.grace + const Duration(seconds: 1));

    expect(PairingWindowService.isOpen, isFalse);
    expect(
      PairingWindowService.mayIntroduceTo(isSavedContact: false),
      isFalse,
    );
    // Contacts are unaffected by the window expiring.
    expect(
      PairingWindowService.mayIntroduceTo(isSavedContact: true),
      isTrue,
    );
  });

  test('an open screen keeps the window open indefinitely', () {
    PairingWindowService.open();

    clock = clock.add(const Duration(hours: 3));

    expect(PairingWindowService.isOpen, isTrue);
  });

  test('close without a matching open does not open the window', () {
    // Defensive: a stray dispose must not hand out a grace period.
    PairingWindowService.close();

    expect(PairingWindowService.isOpen, isFalse);
  });

  test('reopening clears a pending grace period', () {
    PairingWindowService.open();
    PairingWindowService.close();
    PairingWindowService.open();

    clock = clock.add(const Duration(hours: 1));

    // Still open because the screen is up, not because of the stale grace.
    expect(PairingWindowService.isOpen, isTrue);

    PairingWindowService.close();
    clock = clock.add(PairingWindowService.grace + const Duration(seconds: 1));
    expect(PairingWindowService.isOpen, isFalse);
  });
}
