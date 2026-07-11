# Unsync P2P Messenger - Security Audit Report

## Executive Summary
A comprehensive static secure-code review of the Unsync workspace has been conducted. The audit focused on Cryptographic Handshake & Identity, Ratcheting & Forward Secrecy, Local Data Persistence, and Transport & Metadata Security. 

While the use of the `libsignal_protocol_dart` library is a good foundation for end-to-end encryption, the implementation suffers from critical flaws in key verification, unencrypted local storage, signaling server trust, and hardcoded credentials. These vulnerabilities expose users to Man-in-the-Middle (MitM) attacks, local data theft, and metadata leakage.

---

## 1. Cryptographic Handshake & Identity

### [High] Lack of Identity Verification (TOFU without Safety Numbers)
* **Location:** `lib/services/signal_service.dart` (`processPreKeyBundleFromMap`, line 139)
* **Description:** When the application receives a PreKeyBundle (presumably from the relay or signaling server), it blindly decodes and trusts the `identityKey`, `preKey`, and `signedPreKey`. There is no mechanism to verify the Identity Key (e.g., via Safety Numbers or out-of-band QR code scanning). A compromised relay server could substitute its own PreKeyBundle and successfully MitM the Signal session.
* **Remediation:** Implement an out-of-band key verification mechanism. Calculate fingerprints (Safety Numbers) of the Identity Keys and provide a UI for users to compare them (e.g., by scanning a QR code) to ensure the key actually belongs to the intended peer.

### [High] Plaintext WebRTC Signaling (Signaling Server Trust)
* **Location:** `lib/services/signaling_service.dart` (lines 95-103, 140-169) & production signaling server (`unsyncsoftware/unsync-cloaknet`, local checkout `C:\dev\unsync-signaling\server.js`, VPS `/root/signaling/server.js`)
* **Description:** The WebRTC Session Description Protocol (SDP) offers and answers are sent in plaintext via the signaling websocket. While WebRTC uses DTLS-SRTP, an attacker controlling the signaling server can manipulate the SDPs to inject themselves as a proxy, MitM'ing the entire WebRTC connection (both data channels and audio). 
* **Remediation:** Since there is a Signal Protocol session established, you should encrypt the WebRTC SDP offers and answers *using the Signal session* before sending them over the signaling server. The signaling server should only route encrypted blobs.

---

## 2. Ratcheting & Forward Secrecy

### [Medium] Improper Storage of Ephemeral Keys & Session State
* **Location:** `lib/services/signal_service.dart` (`_PersistentSignalStore`, lines 37-54)
* **Description:** The `_PersistentSignalStore` serializes the entire Signal session record (which includes root keys, chain keys, and ephemeral message keys) into a Base64 string and writes it to `SharedPreferences`. If this local file is extracted by malware or an attacker with physical access, they can potentially decrypt past or future messages if the session keys haven't advanced far enough, undermining forward secrecy.
* **Remediation:** Transition from `SharedPreferences` to a secure, encrypted local database (like `sqflite` with `sqlcipher`) or use `flutter_secure_storage` which utilizes the Android Keystore and iOS Keychain.

---

## 3. Local Data Persistence

### [High] Unencrypted Storage of Private Identity Keys
* **Location:** `lib/services/signal_service.dart` (`initialize`, lines 90-93)
* **Description:** The long-term Signal `IdentityKeyPair` (which contains the user's private key) is generated and stored in plaintext using `SharedPreferences` (`signal_identity_key_pair`). `SharedPreferences` data is stored unencrypted in an XML/plist file in the app's sandboxed directory. A compromised device or a physical extraction will immediately yield the user's private identity key.
* **Remediation:** Store the `IdentityKeyPair` exclusively in `flutter_secure_storage`.

### [High] Unencrypted Chat History
* **Location:** `lib/services/messages_service.dart` (`_save`, lines 58-64)
* **Description:** Messages are stored completely in plaintext within `SharedPreferences` under the key `messages_$peerId`. End-to-end encryption is rendered useless if the messages are stored in plaintext at rest on the local device.
* **Remediation:** Migrate chat history storage to an encrypted database. Only keep messages in memory, or use `sqflite` configured with `sqlcipher` using a database key securely generated and stored in the secure enclave/keystore.

---

## 4. Transport & Metadata Security

### [Medium] Hardcoded TURN Server Credentials
* **Location:** `lib/services/webrtc_service.dart` (lines 24-28)
* **Description:** The TURN server URI (`turn:64.188.17.219:3478`), username (`unsync`), and password (`unsync123`) are hardcoded directly into the client source code. Anyone who downloads the app or decompiles the binary can extract these credentials and abuse the TURN server for their own traffic, leading to denial of service or extreme bandwidth costs.
* **Remediation:** Implement a mechanism to fetch short-lived, time-limited TURN credentials (e.g., using the COTURN REST API) from an authenticated backend endpoint rather than hardcoding them in the client.

### [Medium] Metadata Leakage at the Signaling & Relay Servers
* **Location:** production signaling server (`unsyncsoftware/unsync-cloaknet/server.js`) & `server/relay/relay.js` (lines 43-48)
* **Description:** The server implementations log the exact source (`myId`) and destination (`msg.to`) for knocks, calls, and queued messages. This provides a central point of observation for metadata, allowing the server operator (or an attacker who compromised the server) to build a precise social graph of who is talking to whom and when.
* **Remediation:** Remove sensitive metadata logging in production. Consider using a "sealed sender" architecture or obfuscated routing where the server only knows the destination and not the source, or route signaling over an anonymizing network.
