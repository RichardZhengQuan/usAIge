#!/usr/bin/env swift
// Signs site/public/update.json with the release key from
// ~/.config/usaige/update-signing-key. Usage: sign-update-manifest.swift <update.json>
// The signed payload must match UpdateManifest.signedPayload in the app.
import CryptoKit
import Foundation

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: sign-update-manifest.swift <update.json>\n".utf8))
    exit(2)
}
let manifestURL = URL(fileURLWithPath: CommandLine.arguments[1])
let keyURL = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".config/usaige/update-signing-key")
guard let storedText = try? String(contentsOf: keyURL, encoding: .utf8) else {
    FileHandle.standardError.write(Data("no update signing key at \(keyURL.path); run scripts/generate-update-signing-key.swift\n".utf8))
    exit(1)
}
guard let rawKey = Data(base64Encoded: storedText.trimmingCharacters(in: .whitespacesAndNewlines)),
      let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: rawKey) else {
    FileHandle.standardError.write(Data("\(keyURL.path) is not a base64 Ed25519 private key\n".utf8))
    exit(1)
}

var manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as! [String: Any]
guard let version = manifest["version"] as? String,
      let build = manifest["build"] as? Int,
      let sha256 = manifest["sha256"] as? String else {
    FileHandle.standardError.write(Data("update.json is missing version, build, or sha256\n".utf8))
    exit(1)
}
// Keep in step with UpdateManifest.signedPayload: the download URL is not
// signed because the SHA-256 pins the disk image and the legacy site export
// rewrites the URL for its host.
let payload = Data("usaige-update-v2\n\(version)\n\(build)\n\(sha256.lowercased())\n".utf8)
manifest["signature"] = try key.signature(for: payload).base64EncodedString()
let output = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
try output.write(to: manifestURL)
print("Signed \(manifestURL.path) with \(key.publicKey.rawRepresentation.base64EncodedString())")
