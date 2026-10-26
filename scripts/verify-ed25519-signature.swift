// EdDSA（ed25519）署名を公開鍵で検証する。scripts/release-macos.sh が、Sparkle の sign_update で署名した
// 更新アーカイブを、アプリに入れる公開鍵で検証するのに使う（秘密鍵と公開鍵の食い違いを配布前に見つける）。
// 使い方: swift scripts/verify-ed25519-signature.swift <公開鍵の Base64> <署名の Base64> <ファイル>
// 終了コード: 0 = 正しい署名、1 = 署名が合わない、2 = 引数・鍵・署名の形式の誤り。何も出力しない。
import CryptoKit
import Foundation

let arguments = CommandLine.arguments
guard arguments.count == 4,
  let keyData = Data(base64Encoded: arguments[1]),
  let signature = Data(base64Encoded: arguments[2]),
  let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData),
  let message = FileManager.default.contents(atPath: arguments[3])
else {
  exit(2)
}
exit(publicKey.isValidSignature(signature, for: message) ? 0 : 1)
