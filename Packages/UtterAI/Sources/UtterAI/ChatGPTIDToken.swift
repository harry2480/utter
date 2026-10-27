import Foundation
import Security

/// ID トークンで確かめたアカウント（S3）。`sub` をアカウントの識別に使う
struct ChatGPTIdentity: Hashable, Sendable {
  let subject: String
  let email: String?
}

/// RS256（RSASSA-PKCS1-v1_5 + SHA-256）の署名を確かめる。本番は `SecurityRS256Verifier`、
/// テストは鍵を作らずに結果を決められる Stub を使える
protocol RS256SignatureVerifying: Sendable {
  func verify(signature: Data, of message: Data, with key: ChatGPTSigningKey) -> Bool
}

/// Security.framework による RS256 の署名検証。2048 ビット未満の鍵は使わない
struct SecurityRS256Verifier: RS256SignatureVerifying {
  func verify(signature: Data, of message: Data, with key: ChatGPTSigningKey) -> Bool {
    guard let modulus = base64URLDecoded(key.n), let exponent = base64URLDecoded(key.e) else {
      return false
    }
    let significant = modulus.drop { $0 == 0 }
    guard significant.count >= 256 else { return false }
    let attributes: [String: Any] = [
      kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
      kSecAttrKeyClass as String: kSecAttrKeyClassPublic,
    ]
    let der = Self.publicKeyDER(modulus: modulus, exponent: exponent)
    guard let secKey = SecKeyCreateWithData(der as CFData, attributes as CFDictionary, nil) else {
      return false
    }
    return SecKeyVerifySignature(
      secKey, .rsaSignatureMessagePKCS1v15SHA256, message as CFData, signature as CFData, nil)
  }

  /// PKCS #1 の RSAPublicKey（`SEQUENCE { INTEGER n, INTEGER e }`）の DER
  static func publicKeyDER(modulus: Data, exponent: Data) -> Data {
    let body = derInteger(modulus) + derInteger(exponent)
    return Data([0x30]) + derLength(body.count) + body
  }

  private static func derInteger(_ value: Data) -> Data {
    var bytes = Data(value.drop { $0 == 0 })
    if bytes.isEmpty {
      bytes = Data([0])
    }
    // 先頭のビットが立っていると負の数になるため、0 を前に足す
    if let first = bytes.first, first & 0x80 != 0 {
      bytes.insert(0, at: 0)
    }
    return Data([0x02]) + derLength(bytes.count) + bytes
  }

  private static func derLength(_ length: Int) -> Data {
    guard length >= 0x80 else {
      return Data([UInt8(length)])
    }
    var bytes: [UInt8] = []
    var remaining = length
    while remaining > 0 {
      bytes.insert(UInt8(remaining & 0xFF), at: 0)
      remaining >>= 8
    }
    return Data([0x80 | UInt8(bytes.count)] + bytes)
  }
}

/// ID トークン（JWT）の検証（S3）。署名（公開 JWKS, RS256）・`iss`・`aud`・`exp`・`nonce`・`sub` を確かめる。
///
/// ID トークンの値・クレームはログ・エラーに出さない。
struct ChatGPTIDTokenValidator: Sendable {
  /// 時刻のずれの許容（S3 が参照する例と同じ 5 秒）
  static let clockTolerance: TimeInterval = 5

  var signatureVerifier: any RS256SignatureVerifying = SecurityRS256Verifier()

  /// - Parameters:
  ///   - keys: 認証サーバーの JWKS の鍵。トークンが指す鍵の URL は使わない
  ///   - clientID: 発行済みのクライアントID。`aud` に含まれていなければ拒否する
  ///   - nonce: この試行で送った nonce
  func validate(
    _ token: String, keys: [ChatGPTSigningKey], clientID: String, nonce: String, now: Date
  ) throws(ChatGPTSignInError) -> ChatGPTIdentity {
    let parts = token.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count == 3,
      let headerData = base64URLDecoded(parts[0]),
      let payloadData = base64URLDecoded(parts[1]),
      let signature = base64URLDecoded(parts[2]),
      let header = try? JSONDecoder().decode(Header.self, from: headerData),
      header.alg == "RS256", let kid = header.kid, !kid.isEmpty
    else {
      throw .invalidIDToken
    }
    guard let key = keys.first(where: { Self.isSigningKey($0, kid: kid) }) else {
      throw .invalidIDToken
    }
    let message = Data("\(parts[0]).\(parts[1])".utf8)
    guard signatureVerifier.verify(signature: signature, of: message, with: key) else {
      throw .invalidIDToken
    }
    guard let claims = try? JSONDecoder().decode(Claims.self, from: payloadData) else {
      throw .invalidIDToken
    }
    let tolerance = Self.clockTolerance
    guard claims.iss == ChatGPTSignIn.issuer,
      claims.aud.values.contains(clientID),
      Date(timeIntervalSince1970: claims.exp) > now.addingTimeInterval(-tolerance),
      let tokenNonce = claims.nonce,
      ChatGPTAuthorizationAttempt.constantTimeEquals(tokenNonce, nonce),
      let subject = claims.sub, !subject.isEmpty
    else {
      throw .invalidIDToken
    }
    return ChatGPTIdentity(subject: subject, email: claims.email)
  }

  /// トークンの `kid` が指す、RS256 の署名用の RSA 鍵か
  private static func isSigningKey(_ key: ChatGPTSigningKey, kid: String) -> Bool {
    guard key.kid == kid, key.kty == "RSA" else { return false }
    return (key.alg ?? "RS256") == "RS256" && (key.use ?? "sig") == "sig"
  }

  private struct Header: Decodable {
    let alg: String
    let kid: String?
  }

  private struct Claims: Decodable {
    let iss: String
    let sub: String?
    let aud: Audience
    let exp: TimeInterval
    let nonce: String?
    let email: String?
  }

  /// `aud` は文字列か文字列の配列（S3 の例は配列）
  private struct Audience: Decodable {
    let values: [String]

    init(from decoder: any Decoder) throws {
      let container = try decoder.singleValueContainer()
      if let single = try? container.decode(String.self) {
        values = [single]
      } else {
        values = try container.decode([String].self)
      }
    }
  }
}
