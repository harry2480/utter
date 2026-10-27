import Foundation
import Security
import Testing

@testable import UtterAI

struct ChatGPTIDTokenTests {
  private let nonce = "expected-nonce"
  private let now = ChatGPTTestSupport.now
  private let keys = [ChatGPTTestSupport.signingKey]

  private func validate(
    _ token: String, validator: ChatGPTIDTokenValidator = ChatGPTTestSupport.validator()
  ) throws(ChatGPTSignInError) -> ChatGPTIdentity {
    try validator.validate(
      token, keys: keys, clientID: ChatGPTTestSupport.clientID, nonce: nonce, now: now)
  }

  @Test("S3: iss・aud・exp・nonce・sub が合えば、sub とメールアドレスを返す")
  func validToken() throws {
    let identity = try validate(
      ChatGPTTestSupport.idToken(claims: ChatGPTTestSupport.claims(nonce: nonce)))
    #expect(identity.subject == ChatGPTTestSupport.subject)
    #expect(identity.email == ChatGPTTestSupport.email)
    // aud は文字列でもよい
    let single = ChatGPTTestSupport.claims(nonce: nonce, audience: ChatGPTTestSupport.clientID)
    #expect(try validate(ChatGPTTestSupport.idToken(claims: single)).subject == "user-subject")
  }

  @Test("S3: 署名・nonce・aud・iss・exp・sub のどれかが合わなければ拒否する")
  func invalidTokens() {
    var cases: [[String: Any]] = []
    cases.append(ChatGPTTestSupport.claims(nonce: "other-nonce"))
    cases.append(ChatGPTTestSupport.claims(nonce: nonce, audience: ["oaiapp_other"]))
    cases.append(
      ChatGPTTestSupport.claims(nonce: nonce, expiresAt: now.addingTimeInterval(-60)))
    cases.append(ChatGPTTestSupport.claims(nonce: nonce, subject: ""))
    var wrongIssuer = ChatGPTTestSupport.claims(nonce: nonce)
    wrongIssuer["iss"] = "https://auth.example.com"
    cases.append(wrongIssuer)
    var noNonce = ChatGPTTestSupport.claims(nonce: nonce)
    noNonce["nonce"] = nil
    cases.append(noNonce)
    for claims in cases {
      #expect(throws: ChatGPTSignInError.invalidIDToken) {
        try validate(ChatGPTTestSupport.idToken(claims: claims))
      }
    }

    let valid = ChatGPTTestSupport.idToken(claims: ChatGPTTestSupport.claims(nonce: nonce))
    #expect(throws: ChatGPTSignInError.invalidIDToken) {
      try validate(valid, validator: ChatGPTTestSupport.validator(accepts: false))
    }
  }

  @Test("S3: RS256 以外・鍵が見つからない・JWT の形でないトークンは拒否する")
  func invalidHeaders() {
    let claims = ChatGPTTestSupport.claims(nonce: nonce)
    let tokens = [
      ChatGPTTestSupport.idToken(header: ["alg": "none", "kid": "key-1"], claims: claims),
      ChatGPTTestSupport.idToken(header: ["alg": "HS256", "kid": "key-1"], claims: claims),
      ChatGPTTestSupport.idToken(header: ["alg": "RS256", "kid": "unknown"], claims: claims),
      ChatGPTTestSupport.idToken(header: ["alg": "RS256"], claims: claims),
      "not-a-jwt",
      "a.b",
    ]
    for token in tokens {
      #expect(throws: ChatGPTSignInError.invalidIDToken) { try validate(token) }
    }
  }

  @Test("S3: Security.framework の RS256 で、本物の署名だけを受け付ける")
  func realRS256Signature() throws {
    let attributes: [String: Any] = [
      kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
      kSecAttrKeySizeInBits as String: 2048,
    ]
    let privateKey = try #require(SecKeyCreateRandomKey(attributes as CFDictionary, nil))
    let publicKey = try #require(SecKeyCopyPublicKey(privateKey))
    let der = try #require(SecKeyCopyExternalRepresentation(publicKey, nil) as Data?)
    var reader = DERReader(der)
    let components = try #require(reader.rsaPublicKey())
    let key = ChatGPTSigningKey(
      kty: "RSA", kid: "real", alg: "RS256", use: "sig",
      n: base64URLEncoded(components.modulus), e: base64URLEncoded(components.exponent))

    let header = base64URLEncoded(Data(#"{"alg":"RS256","kid":"real"}"#.utf8))
    let claims = try JSONSerialization.data(
      withJSONObject: ChatGPTTestSupport.claims(nonce: nonce))
    let payload = base64URLEncoded(claims)
    let message = Data("\(header).\(payload)".utf8)
    let signature = try #require(
      SecKeyCreateSignature(
        privateKey, .rsaSignatureMessagePKCS1v15SHA256, message as CFData, nil) as Data?)
    let token = "\(header).\(payload).\(base64URLEncoded(signature))"

    let validator = ChatGPTIDTokenValidator()
    let identity = try validator.validate(
      token, keys: [key], clientID: ChatGPTTestSupport.clientID, nonce: nonce, now: now)
    #expect(identity.subject == ChatGPTTestSupport.subject)

    // 署名のあとで中身を変えたトークンは拒否する
    var tampered = ChatGPTTestSupport.claims(nonce: nonce)
    tampered["sub"] = "someone-else"
    let tamperedPayload = base64URLEncoded(try JSONSerialization.data(withJSONObject: tampered))
    let forged = "\(header).\(tamperedPayload).\(base64URLEncoded(signature))"
    #expect(throws: ChatGPTSignInError.invalidIDToken) {
      try validator.validate(
        forged, keys: [key], clientID: ChatGPTTestSupport.clientID, nonce: nonce, now: now)
    }
  }

  @Test("PKCS #1 の DER: 先頭のビットが立った整数には 0 を足し、長い長さは複数バイトで書く")
  func publicKeyDEREncoding() {
    let der = SecurityRS256Verifier.publicKeyDER(
      modulus: Data(repeating: 0xFF, count: 256), exponent: Data([0x01, 0x00, 0x01]))
    var reader = DERReader(der)
    let components = reader.rsaPublicKey()
    #expect(components?.modulus == Data([0x00]) + Data(repeating: 0xFF, count: 256))
    #expect(components?.exponent == Data([0x01, 0x00, 0x01]))
    // SEQUENCE の長さは 2 バイト（0x82）
    #expect(der.prefix(2) == Data([0x30, 0x82]))
  }
}

/// テスト用の最小の DER の読み取り（RSAPublicKey だけ）
private struct DERReader {
  private let bytes: [UInt8]
  private var index = 0

  init(_ data: Data) {
    bytes = [UInt8](data)
  }

  /// `SEQUENCE { INTEGER n, INTEGER e }` を読む。先頭の 0 は落とさない
  mutating func rsaPublicKey() -> (modulus: Data, exponent: Data)? {
    guard index < bytes.count, bytes[index] == 0x30 else { return nil }
    index += 1
    guard readLength() != nil else { return nil }
    guard let modulus = read(tag: 0x02), let exponent = read(tag: 0x02) else { return nil }
    return (modulus, exponent)
  }

  private mutating func readLength() -> Int? {
    guard index < bytes.count else { return nil }
    let first = bytes[index]
    index += 1
    guard first & 0x80 != 0 else { return Int(first) }
    var length = 0
    for _ in 0..<Int(first & 0x7F) {
      guard index < bytes.count else { return nil }
      length = (length << 8) | Int(bytes[index])
      index += 1
    }
    return length
  }

  private mutating func read(tag: UInt8) -> Data? {
    guard index < bytes.count, bytes[index] == tag else { return nil }
    index += 1
    guard let length = readLength(), index + length <= bytes.count else { return nil }
    let value = Data(bytes[index..<(index + length)])
    index += length
    return value
  }
}
