import CryptoKit
import Foundation

// Public key and signature are not secrets. Private material never reaches argv.
guard CommandLine.arguments.count == 4,
      let key = Data(base64Encoded: CommandLine.arguments[1]), key.count == 32,
      let signature = Data(base64Encoded: CommandLine.arguments[3]), signature.count == 64,
      let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: key),
      let data = try? Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2]), options: .mappedIfSafe),
      publicKey.isValidSignature(signature, for: data) else {
    fputs("Update signature verification failed.\n", stderr)
    exit(1)
}
