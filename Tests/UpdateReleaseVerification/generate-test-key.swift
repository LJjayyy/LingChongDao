import CryptoKit
import Foundation

// Ephemeral verification fixture only. Never installs a key in the Keychain.
guard CommandLine.arguments.count == 2 else { exit(2) }
let key = Curve25519.Signing.PrivateKey()
let publicBytes = key.publicKey.rawRepresentation
let values = ["public": publicBytes.base64EncodedString(),
              "private": key.rawRepresentation.base64EncodedString()]
let url = URL(fileURLWithPath: CommandLine.arguments[1])
try JSONSerialization.data(withJSONObject: values).write(to: url, options: .atomic)
try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
