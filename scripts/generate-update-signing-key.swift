#!/usr/bin/env swift
// Creates the Ed25519 key that signs update.json. Run once on the release
// Mac; the private key never leaves ~/.config/usaige. Paste the printed
// public key into UpdateSigning.pinnedPublicKeyBase64 and ship a release,
// after which every update manifest must carry a matching signature.
import CryptoKit
import Foundation

let directory = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".config/usaige", isDirectory: true)
let keyURL = directory.appendingPathComponent("update-signing-key")

if FileManager.default.fileExists(atPath: keyURL.path) {
    let stored = try String(contentsOf: keyURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
    guard let rawKey = Data(base64Encoded: stored),
          let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: rawKey) else {
        FileHandle.standardError.write(Data("\(keyURL.path) is not a base64 Ed25519 private key\n".utf8))
        exit(1)
    }
    print("Key already exists at \(keyURL.path)")
    print("Public key: \(key.publicKey.rawRepresentation.base64EncodedString())")
    exit(0)
}

try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
let key = Curve25519.Signing.PrivateKey()
guard FileManager.default.createFile(
    atPath: keyURL.path,
    contents: Data(key.rawRepresentation.base64EncodedString().utf8),
    attributes: [.posixPermissions: 0o600]
) else {
    FileHandle.standardError.write(Data("Could not write \(keyURL.path)\n".utf8))
    exit(1)
}
print("Wrote private key to \(keyURL.path) (back it up; losing it breaks in-app updates)")
print("Public key: \(key.publicKey.rawRepresentation.base64EncodedString())")
