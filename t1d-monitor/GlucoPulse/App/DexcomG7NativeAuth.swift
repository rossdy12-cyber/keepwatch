import Foundation
import CoreBluetooth
import CryptoKit
import CommonCrypto
import Security

// MARK: - Pure-Swift 256-Bit Modular & P-256 Affine Arithmetic for Dexcom G7 J-PAKE

struct G7U256: Equatable {
    // Little-endian 64-bit limbs: w0 is least significant, w3 is most significant
    var w0: UInt64 = 0
    var w1: UInt64 = 0
    var w2: UInt64 = 0
    var w3: UInt64 = 0

    static let zero = G7U256()
    static let one  = G7U256(w0: 1, w1: 0, w2: 0, w3: 0)
    static let two  = G7U256(w0: 2, w1: 0, w2: 0, w3: 0)
    static let three = G7U256(w0: 3, w1: 0, w2: 0, w3: 0)

    // secp256r1 prime field modulus P
    static let P = G7U256(
        w0: 0xFFFFFFFFFFFFFFFF,
        w1: 0x00000000FFFFFFFF,
        w2: 0x0000000000000000,
        w3: 0xFFFFFFFF00000001
    )

    // secp256r1 order N
    static let N = G7U256(
        w0: 0xF3B9CAC2FC632551,
        w1: 0xBCE6FAADA7179E84,
        w2: 0xFFFFFFFFFFFFFFFF,
        w3: 0xFFFFFFFF00000000
    )

    // secp256r1 curve parameter B
    static let B = G7U256(
        w0: 0x3BCE3C3E27D2604B,
        w1: 0x651D06B0CC53B0F6,
        w2: 0xB3EBBD55769886BC,
        w3: 0x5AC635D8AA3A93E7
    )

    init(w0: UInt64 = 0, w1: UInt64 = 0, w2: UInt64 = 0, w3: UInt64 = 0) {
        self.w0 = w0; self.w1 = w1; self.w2 = w2; self.w3 = w3
    }

    init(bigEndianBytes data: Data) {
        var padded = [UInt8](repeating: 0, count: 32)
        let bytes = [UInt8](data)
        if bytes.count >= 32 {
            padded = Array(bytes.suffix(32))
        } else {
            padded.replaceSubrange((32 - bytes.count)..<32, with: bytes)
        }
        func readBE64(_ offset: Int) -> UInt64 {
            var v: UInt64 = 0
            for i in 0..<8 {
                v = (v << 8) | UInt64(padded[offset + i])
            }
            return v
        }
        self.w3 = readBE64(0)
        self.w2 = readBE64(8)
        self.w1 = readBE64(16)
        self.w0 = readBE64(24)
    }

    var bigEndianData: Data {
        var out = [UInt8](repeating: 0, count: 32)
        func writeBE64(_ v: UInt64, _ offset: Int) {
            for i in 0..<8 {
                out[offset + i] = UInt8((v >> ((7 - i) * 8)) & 0xFF)
            }
        }
        writeBE64(w3, 0)
        writeBE64(w2, 8)
        writeBE64(w1, 16)
        writeBE64(w0, 24)
        return Data(out)
    }

    var isZero: Bool {
        w0 == 0 && w1 == 0 && w2 == 0 && w3 == 0
    }

    func bit(_ idx: Int) -> Bool {
        let wordIdx = idx >> 6
        let bitIdx = idx & 63
        let w: UInt64
        switch wordIdx {
        case 0: w = w0
        case 1: w = w1
        case 2: w = w2
        default: w = w3
        }
        return ((w >> bitIdx) & 1) == 1
    }

    static func cmp(_ a: G7U256, _ b: G7U256) -> Int {
        if a.w3 != b.w3 { return a.w3 < b.w3 ? -1 : 1 }
        if a.w2 != b.w2 { return a.w2 < b.w2 ? -1 : 1 }
        if a.w1 != b.w1 { return a.w1 < b.w1 ? -1 : 1 }
        if a.w0 != b.w0 { return a.w0 < b.w0 ? -1 : 1 }
        return 0
    }

    static func add(_ a: G7U256, _ b: G7U256) -> (G7U256, Bool) {
        let (s0, c0) = a.w0.addingReportingOverflow(b.w0)
        let (s1a, c1a) = a.w1.addingReportingOverflow(b.w1)
        let (s1, c1b) = s1a.addingReportingOverflow(c0 ? 1 : 0)
        let c1 = c1a || c1b

        let (s2a, c2a) = a.w2.addingReportingOverflow(b.w2)
        let (s2, c2b) = s2a.addingReportingOverflow(c1 ? 1 : 0)
        let c2 = c2a || c2b

        let (s3a, c3a) = a.w3.addingReportingOverflow(b.w3)
        let (s3, c3b) = s3a.addingReportingOverflow(c2 ? 1 : 0)
        let c3 = c3a || c3b

        return (G7U256(w0: s0, w1: s1, w2: s2, w3: s3), c3)
    }

    static func sub(_ a: G7U256, _ b: G7U256) -> (G7U256, Bool) {
        let (d0, b0) = a.w0.subtractingReportingOverflow(b.w0)
        let (d1a, b1a) = a.w1.subtractingReportingOverflow(b.w1)
        let (d1, b1b) = d1a.subtractingReportingOverflow(b0 ? 1 : 0)
        let br1 = b1a || b1b

        let (d2a, b2a) = a.w2.subtractingReportingOverflow(b.w2)
        let (d2, b2b) = d2a.subtractingReportingOverflow(br1 ? 1 : 0)
        let br2 = b2a || b2b

        let (d3a, b3a) = a.w3.subtractingReportingOverflow(b.w3)
        let (d3, b3b) = d3a.subtractingReportingOverflow(br2 ? 1 : 0)
        let br3 = b3a || b3b

        return (G7U256(w0: d0, w1: d1, w2: d2, w3: d3), br3)
    }

    static func modReduce(_ a: G7U256, _ m: G7U256) -> G7U256 {
        var r = a
        while cmp(r, m) >= 0 {
            r = sub(r, m).0
        }
        return r
    }

    static func modAdd(_ a: G7U256, _ b: G7U256, _ m: G7U256) -> G7U256 {
        let ar = modReduce(a, m)
        let br = modReduce(b, m)
        let (s, carry) = add(ar, br)
        if carry || cmp(s, m) >= 0 {
            return sub(s, m).0
        }
        return s
    }

    static func modSub(_ a: G7U256, _ b: G7U256, _ m: G7U256) -> G7U256 {
        let ar = modReduce(a, m)
        let br = modReduce(b, m)
        if cmp(ar, br) >= 0 {
            return sub(ar, br).0
        } else {
            let diff = sub(m, br).0
            return modAdd(ar, diff, m)
        }
    }

    static func modMul(_ a: G7U256, _ b: G7U256, _ m: G7U256) -> G7U256 {
        var result = G7U256.zero
        var addend = modReduce(a, m)
        let mult = modReduce(b, m)
        for i in 0..<256 {
            if mult.bit(i) {
                result = modAdd(result, addend, m)
            }
            addend = modAdd(addend, addend, m)
        }
        return result
    }

    static func modPow(_ base: G7U256, _ exp: G7U256, _ m: G7U256) -> G7U256 {
        var result = G7U256.one
        var b = modReduce(base, m)
        for i in 0..<256 {
            if exp.bit(i) {
                result = modMul(result, b, m)
            }
            b = modMul(b, b, m)
        }
        return result
    }

    static func modInv(_ a: G7U256, _ m: G7U256) -> G7U256? {
        let ar = modReduce(a, m)
        if ar.isZero { return nil }
        let exp = sub(m, G7U256.two).0
        return modPow(ar, exp, m)
    }
}

struct G7ECPoint: Equatable {
    var x: G7U256
    var y: G7U256

    static let generator = G7ECPoint(
        x: G7U256(
            w0: 0xF4A13945D898C296,
            w1: 0x77037D812DEB33A0,
            w2: 0xF8BCE6E563A440F2,
            w3: 0x6B17D1F2E12C4247
        ),
        y: G7U256(
            w0: 0xCBB6406837BF51F5,
            w1: 0x2BCE33576B315ECE,
            w2: 0x8EE7EB4A7C0F9E16,
            w3: 0x4FE342E2FE1A7F9B
        )
    )

    init(x: G7U256, y: G7U256) {
        self.x = x
        self.y = y
    }

    init?(raw64Bytes data: Data) {
        guard data.count == 64 else { return nil }
        let px = G7U256(bigEndianBytes: data.subdata(in: 0..<32))
        let py = G7U256(bigEndianBytes: data.subdata(in: 32..<64))
        let pt = G7ECPoint(x: px, y: py)
        guard pt.isValidOnCurve else { return nil }
        self = pt
    }

    var raw64Data: Data {
        var d = Data(capacity: 64)
        d.append(x.bigEndianData)
        d.append(y.bigEndianData)
        return d
    }

    var isValidOnCurve: Bool {
        if x.isZero || y.isZero { return false }
        if G7U256.cmp(x, .P) >= 0 || G7U256.cmp(y, .P) >= 0 { return false }
        let lhs = G7U256.modMul(y, y, .P)
        let x2 = G7U256.modMul(x, x, .P)
        let x3 = G7U256.modMul(x2, x, .P)
        let threeX = G7U256.modMul(.three, x, .P)
        let rhs = G7U256.modAdd(G7U256.modSub(x3, threeX, .P), .B, .P)
        return lhs == rhs
    }

    func negated() -> G7ECPoint {
        if y.isZero { return self }
        return G7ECPoint(x: x, y: G7U256.modSub(.P, y, .P))
    }

    static func double(_ pt: G7ECPoint) -> G7ECPoint? {
        if pt.y.isZero { return nil }
        let x2 = G7U256.modMul(pt.x, pt.x, .P)
        let num = G7U256.modSub(G7U256.modMul(.three, x2, .P), .three, .P)
        let den = G7U256.modMul(.two, pt.y, .P)
        guard let inv = G7U256.modInv(den, .P) else { return nil }
        let lam = G7U256.modMul(num, inv, .P)
        let lam2 = G7U256.modMul(lam, lam, .P)
        let twoX = G7U256.modMul(.two, pt.x, .P)
        let rx = G7U256.modSub(lam2, twoX, .P)
        let ry = G7U256.modSub(G7U256.modMul(lam, G7U256.modSub(pt.x, rx, .P), .P), pt.y, .P)
        return G7ECPoint(x: rx, y: ry)
    }

    static func add(_ p1: G7ECPoint, _ p2: G7ECPoint) -> G7ECPoint? {
        if p1.x == p2.x {
            if p1.y == p2.y {
                return double(p1)
            }
            return nil
        }
        let dx = G7U256.modSub(p2.x, p1.x, .P)
        let dy = G7U256.modSub(p2.y, p1.y, .P)
        guard let inv = G7U256.modInv(dx, .P) else { return nil }
        let lam = G7U256.modMul(dy, inv, .P)
        let lam2 = G7U256.modMul(lam, lam, .P)
        let rx = G7U256.modSub(G7U256.modSub(lam2, p1.x, .P), p2.x, .P)
        let ry = G7U256.modSub(G7U256.modMul(lam, G7U256.modSub(p1.x, rx, .P), .P), p1.y, .P)
        return G7ECPoint(x: rx, y: ry)
    }

    static func subtract(_ p1: G7ECPoint, _ p2: G7ECPoint) -> G7ECPoint? {
        return add(p1, p2.negated())
    }

    static func multiply(_ pt: G7ECPoint, scalar: G7U256) -> G7ECPoint? {
        if scalar.isZero { return nil }
        var res: G7ECPoint? = nil
        var addend: G7ECPoint? = pt
        for i in 0..<256 {
            if scalar.bit(i) {
                if let a = addend {
                    if let cur = res {
                        res = add(cur, a)
                    } else {
                        res = a
                    }
                }
            }
            if let a = addend {
                addend = double(a)
            }
        }
        return res
    }

    static func randomScalarModN() -> G7U256 {
        while true {
            var bytes = [UInt8](repeating: 0, count: 32)
            _ = SecRandomCopyBytes(kSecRandomDefault, 32, &bytes)
            let s = G7U256(bigEndianBytes: Data(bytes))
            if !s.isZero && G7U256.cmp(s, .N) < 0 {
                return s
            }
        }
    }

    static func generateKeyPair() -> (publicKey: G7ECPoint, privateKey: G7U256)? {
        let priv = randomScalarModN()
        guard let pub = multiply(.generator, scalar: priv) else { return nil }
        return (pub, priv)
    }
}

// MARK: - Dexcom G7 Native Crypto & J-PAKE + Certificate + AES-128-ECB Authenticator

final class DexcomG7NativeAuthenticator {
    private static let keksPartAHex =
        "308201EA3082018FA00302010202142F3C52B6EB08701046D45D78CE81784C9DFE5240300A06082A8648CE3D04030230133111300F06035504030C084445583030504731301E170D3230313033303135353930345A170D3335313032373135353930345A30133111300F06035504030C0844455830335047313059301306072A8648CE3D020106082A8648CE3D03010703420004FB1ACA21D8AEEC9A4EB51F85304953D977A1AD569799250FF863987F42A3CD9FA4FF571EB568BC6C396277C3DCB51DEDAEE85513C80A5C4435538A19F5A96348A381C03081BD300F0603551D130101FF040530030101FF301F0603551D230418301680149E0F1E36F3F276A701FE8E883A6E26A635BD6AFC305A0603551D1F04533051304FA034A0328630687474703A2F2F63726C2E64702E736161732E7072696D656B65792E636F6D2F63726C2F44455830305047312E63726CA217A41530133111300F06035504030C084445583030504731301D0603551D0E0416041488F61E81BC4B17F05C6B1BE2991D60087CCEDD79300E0603551D0F0101FF040403020186300A06082A8648CE3D0403020349003046022100AA69CD897EC663AF5F9E158187DF6851FF0756F00C401624564F81A19F5A0785022100DAEBB9FDB163B731EB0661F1C0A1932871A50E399AD1C6F519EABD4C9E7BA013"

    private static let keksPartBHex =
        "308201CD30820174A003020102021419052FCC17530BFA56E49DCAFCDACF853CE5BA73300A06082A8648CE3D04030230133111300F06035504030C084445583033504731301E170D3233303431343130323831345A170D3235303431333130323831335A303A3138303606035504030C2F30312C303030302C303330304C514543437A4142417741412C63696F69653356625132686C5A4D6A64556D357267413059301306072A8648CE3D020106082A8648CE3D030107034200045118C35E9E41E7E0654FEE801C52A9C5DFC510EF09597D5CCA8461E4AF9C666714834F2BC903F16FABFC45755B0183F1A09745CDFFCB4E2F799E50BED9A6B58CA37F307D300C0603551D130101FF04023000301F0603551D2304183016801488F61E81BC4B17F05C6B1BE2991D60087CCEDD79301D0603551D250416301406082B0601050507030206082B06010505070301301D0603551D0E04160414D309E75C0725412D7A7922E3AACFB27F7EBD6BE0300E0603551D0F0101FF0404030205A0300A06082A8648CE3D0403020347003044022048D4868CF393D9044101B6F07FD68D7F0642805F85DA74E2FE9DE8DD3507F02702201CD1BF7C6C7EDD59435E324925FCF0EBB3CAE2110D79407C77AA3B93B7BC04CB"

    private static let keksPartCScalarHex =
        "007CFBD596F6E74477B8C0E9F6F7A174275E101EF6BF7D18CAF01181D127B579"

    private static let aliceParty = Data([0x63, 0x6C, 0x69, 0x65, 0x6E, 0x74]) // "client"
    private static let bobParty   = Data([0x73, 0x65, 0x72, 0x76, 0x65, 0x72]) // "server"
    private static let sharedKeyPrefix = "G7NativeAuthBridge.SharedKey."

    struct PakePacket {
        let publicKey: G7ECPoint
        let proofPoint: G7ECPoint
        let proofScalar: G7U256
    }

    var transmitterID: String = ""
    var pairingCode: String = ""
    var authenticationSlot: UInt8 = 0x02

    private let partA: Data
    private let partB: Data
    private let partC: Data

    private(set) var sharedKey: Data?
    private var lastAuthRequestToken: Data?
    private var privateKeyA: G7U256?
    private var publicKeyA: G7ECPoint?
    private var privateKeyB: G7U256?
    private var publicKeyB: G7ECPoint?
    private var remoteRound1: PakePacket?
    private var remoteRound2: PakePacket?
    private var remoteRound3: PakePacket?

    init(transmitterID: String = "", pairingCode: String = "", slot: UInt8 = 0x02) {
        self.transmitterID = transmitterID
        self.pairingCode = pairingCode
        self.authenticationSlot = slot
        self.partA = Self.dataFromHex(Self.keksPartAHex)
        self.partB = Self.dataFromHex(Self.keksPartBHex)
        self.partC = Self.dataFromHex(Self.keksPartCScalarHex)
        restorePersistedSharedKey()
    }

    private var defaultsKey: String? {
        guard !transmitterID.isEmpty else { return nil }
        let base = Self.sharedKeyPrefix + transmitterID
        if authenticationSlot == 0x02 { return base }
        return String(format: "%@.%02X", base, authenticationSlot)
    }

    func restorePersistedSharedKey() {
        guard let key = defaultsKey,
              let stored = UserDefaults.standard.data(forKey: key),
              stored.count == 16 else {
            return
        }
        self.sharedKey = stored
    }

    func confirmAndPersistSharedKey() {
        guard let key = defaultsKey, let sk = sharedKey, sk.count == 16 else { return }
        UserDefaults.standard.set(sk, forKey: key)
    }

    func clearSharedKey() {
        sharedKey = nil
        if let key = defaultsKey {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    func resetSession() {
        lastAuthRequestToken = nil
        privateKeyA = nil
        publicKeyA = nil
        privateKeyB = nil
        publicKeyB = nil
        remoteRound1 = nil
        remoteRound2 = nil
        remoteRound3 = nil
        restorePersistedSharedKey()
    }

    var hasConfirmedSharedKey: Bool {
        restorePersistedSharedKey()
        return sharedKey?.count == 16
    }

    func makeAuthRequestPacket() -> Data {
        var uuidBytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, 16, &uuidBytes)
        let token = Data(uuidBytes.prefix(8))
        self.lastAuthRequestToken = token
        var pkt = Data([0x02])
        pkt.append(token)
        pkt.append(authenticationSlot)
        return pkt
    }

    func makeInitialControlPacket() -> (packet: Data, isFullBootstrap: Bool)? {
        restorePersistedSharedKey()
        if sharedKey?.count == 16 {
            return (makeAuthRequestPacket(), false)
        }
        let cleanCode = pairingCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleanCode.count == 4 || cleanCode.count == 6 else {
            return nil
        }
        guard ensureLocalPakeKeys() else { return nil }
        return (Data([0x0A, 0x00]), true)
    }

    func makeChallengeResponse(challenge: Data) -> Data? {
        guard challenge.count == 8, let key = sharedKey, key.count == 16 else { return nil }
        var doubleChallenge = Data(capacity: 16)
        doubleChallenge.append(challenge)
        doubleChallenge.append(challenge)
        guard let encrypted = Self.aes128ECBEncrypt(data: doubleChallenge, key: key),
              encrypted.count >= 8 else { return nil }
        var resp = Data([0x04])
        resp.append(encrypted.prefix(8))
        return resp
    }

    func handlePakePhase(_ phase: UInt8, payload: Data) -> (controlPacket: Data, streamPackets: [Data])? {
        guard ensureLocalPakeKeys(),
              let pkt = parsePakePacket(payload) else { return nil }
        switch phase {
        case 0:
            guard validateZeroKnowledge(pkt, base: .generator, party: Self.bobParty),
                  let privA = privateKeyA, let pubA = publicKeyA,
                  let local1 = makePakePacket(privateKey: privA, publicKey: pubA, base: .generator, party: Self.aliceParty) else {
                return nil
            }
            remoteRound1 = pkt
            return (Data([0x0A, 0x01]), Self.chunk20(local1))

        case 1:
            guard validateZeroKnowledge(pkt, base: .generator, party: Self.bobParty),
                  let privB = privateKeyB, let pubB = publicKeyB,
                  let local2 = makePakePacket(privateKey: privB, publicKey: pubB, base: .generator, party: Self.aliceParty) else {
                return nil
            }
            remoteRound2 = pkt
            return (Data([0x0A, 0x02]), Self.chunk20(local2))

        case 2:
            remoteRound3 = pkt
            guard let r1 = remoteRound1, let r2 = remoteRound2,
                  let pubA = publicKeyA, let pubB = publicKeyB, let privB = privateKeyB else {
                return nil
            }
            // Validate remote round 3 with base = pubA + pubB + r1.publicKey
            guard let sumAB = G7ECPoint.add(pubA, pubB),
                  let baseBob3 = G7ECPoint.add(sumAB, r1.publicKey),
                  validateZeroKnowledge(pkt, base: baseBob3, party: Self.bobParty) else {
                return nil
            }
            // Build local round 3 with base = pubA + r1.publicKey + r2.publicKey
            guard let pwScalar = passwordScalar() else { return nil }
            let x2s = G7U256.modMul(privB, pwScalar, .N)
            guard let sumAR1 = G7ECPoint.add(pubA, r1.publicKey),
                  let g134 = G7ECPoint.add(sumAR1, r2.publicKey),
                  let localPub3 = G7ECPoint.multiply(g134, scalar: x2s),
                  let local3 = makePakePacket(privateKey: x2s, publicKey: localPub3, base: g134, party: Self.aliceParty) else {
                return nil
            }
            // Derive 16-byte shared key = SHA256( ((r3.pub - r2.pub * x2s) * privB).x )[0..<16]
            guard let subPt = G7ECPoint.multiply(r2.publicKey, scalar: x2s),
                  let diffPt = G7ECPoint.subtract(pkt.publicKey, subPt),
                  let keyPt = G7ECPoint.multiply(diffPt, scalar: privB) else {
                return nil
            }
            let digest = SHA256.hash(data: keyPt.x.bigEndianData)
            self.sharedKey = Data(digest.prefix(16))
            return (makeAuthRequestPacket(), Self.chunk20(local3))

        default:
            return nil
        }
    }

    func certificateControlPacket(phase: UInt8) -> Data? {
        let size: UInt32
        switch phase {
        case 0: size = UInt32(partA.count)
        case 1: size = UInt32(partB.count)
        case 2: size = 0
        default: return nil
        }
        var d = Data([0x0B, phase])
        var le = size.littleEndian
        withUnsafeBytes(of: &le) { d.append(contentsOf: $0) }
        return d
    }

    func certificateStreamPackets(phase: UInt8) -> [Data] {
        switch phase {
        case 0: return Self.chunk20(partA)
        case 1: return Self.chunk20(partB)
        default: return []
        }
    }

    func makeProofOfPossessionChallengeRequest() -> Data {
        var challenge = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, 16, &challenge)
        var d = Data([0x0C])
        d.append(contentsOf: challenge)
        return d
    }

    func makeProofOfPossessionResponse(challenge: Data) -> (controlPacket: Data, streamPackets: [Data])? {
        guard challenge.count >= 16,
              let privKey = try? P256.Signing.PrivateKey(rawRepresentation: partC) else {
            return nil
        }
        let digest = SHA256.hash(data: challenge.prefix(16))
        guard let sig = try? privKey.signature(for: digest).rawRepresentation,
              sig.count == 64 else {
            return nil
        }
        return (Data([0x0D, 0x00, 0x02]), Self.chunk20(sig))
    }

    // MARK: - Helpers

    private func ensureLocalPakeKeys() -> Bool {
        if privateKeyA != nil && publicKeyA != nil && privateKeyB != nil && publicKeyB != nil {
            return true
        }
        guard let kpA = G7ECPoint.generateKeyPair(),
              let kpB = G7ECPoint.generateKeyPair() else {
            return false
        }
        publicKeyA = kpA.publicKey
        privateKeyA = kpA.privateKey
        publicKeyB = kpB.publicKey
        privateKeyB = kpB.privateKey
        return true
    }

    private func passwordScalar() -> G7U256? {
        let clean = pairingCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, let ascii = clean.data(using: .utf8) else { return nil }
        var bytes = Data()
        if clean.count == 6 {
            bytes.append(contentsOf: [0x30, 0x30])
        }
        bytes.append(ascii)
        return G7U256(bigEndianBytes: bytes)
    }

    private func parsePakePacket(_ data: Data) -> PakePacket? {
        guard data.count >= 160 else { return nil }
        guard let pub = G7ECPoint(raw64Bytes: data.subdata(in: 0..<64)),
              let proofPt = G7ECPoint(raw64Bytes: data.subdata(in: 64..<128)) else {
            return nil
        }
        let scalar = G7U256(bigEndianBytes: data.subdata(in: 128..<160))
        return PakePacket(publicKey: pub, proofPoint: proofPt, proofScalar: scalar)
    }

    private func zkHash(base: G7ECPoint, gv: G7ECPoint, pub: G7ECPoint, party: Data) -> G7U256 {
        var input = Data()
        func appendField(_ field: Data) {
            var beLen = UInt32(field.count).bigEndian
            withUnsafeBytes(of: &beLen) { input.append(contentsOf: $0) }
            input.append(field)
        }
        func uncompressed(_ pt: G7ECPoint) -> Data {
            var d = Data([0x04])
            d.append(pt.raw64Data)
            return d
        }
        appendField(uncompressed(base))
        appendField(uncompressed(gv))
        appendField(uncompressed(pub))
        appendField(party)
        let digest = Data(SHA256.hash(data: input))
        let h = G7U256(bigEndianBytes: digest)
        return G7U256.modReduce(h, .N)
    }

    private func makePakePacket(privateKey: G7U256, publicKey: G7ECPoint, base: G7ECPoint, party: Data) -> Data? {
        let exponent = G7ECPoint.randomScalarModN()
        guard let proofPt = G7ECPoint.multiply(base, scalar: exponent) else { return nil }
        let h = zkHash(base: base, gv: proofPt, pub: publicKey, party: party)
        let prod = G7U256.modMul(h, privateKey, .N)
        let proofScalar = G7U256.modSub(exponent, prod, .N)
        var out = Data(capacity: 160)
        out.append(publicKey.raw64Data)
        out.append(proofPt.raw64Data)
        out.append(proofScalar.bigEndianData)
        return out
    }

    private func validateZeroKnowledge(_ pkt: PakePacket, base: G7ECPoint, party: Data) -> Bool {
        let h = zkHash(base: base, gv: pkt.proofPoint, pub: pkt.publicKey, party: party)
        guard let left = G7ECPoint.multiply(base, scalar: pkt.proofScalar),
              let right = G7ECPoint.multiply(pkt.publicKey, scalar: h),
              let combined = G7ECPoint.add(left, right) else {
            return false
        }
        return combined == pkt.proofPoint
    }

    static func aes128ECBEncrypt(data: Data, key: Data) -> Data? {
        guard data.count == 16 && key.count == 16 else { return nil }
        var outBytes = [UInt8](repeating: 0, count: 16)
        var outLen: Int = 0
        let status = data.withUnsafeBytes { dataPtr in
            key.withUnsafeBytes { keyPtr in
                CCCrypt(
                    CCOperation(kCCEncrypt),
                    CCAlgorithm(kCCAlgorithmAES128),
                    CCOptions(kCCOptionECBMode),
                    keyPtr.baseAddress, 16,
                    nil,
                    dataPtr.baseAddress, 16,
                    &outBytes, 16,
                    &outLen
                )
            }
        }
        guard status == kCCSuccess && outLen == 16 else { return nil }
        return Data(outBytes)
    }

    static func chunk20(_ data: Data) -> [Data] {
        guard !data.isEmpty else { return [] }
        return stride(from: 0, to: data.count, by: 20).map { offset in
            data.subdata(in: offset..<min(offset + 20, data.count))
        }
    }

    static func dataFromHex(_ hex: String) -> Data {
        var d = Data(capacity: hex.count / 2)
        var idx = hex.startIndex
        while idx < hex.endIndex {
            let next = hex.index(idx, offsetBy: 2, limitedBy: hex.endIndex) ?? hex.endIndex
            if let b = UInt8(hex[idx..<next], radix: 16) {
                d.append(b)
            }
            idx = next
        }
        return d
    }
}


// MARK: - Tandem t:slim X2 Native BLE Authenticator (EC-JPAKE 6-Digit + HMAC-SHA1 16-Char + Packetizer)

final class TandemPumpNativeAuthenticator {
    private static let aliceParty = Data([0x63, 0x6C, 0x69, 0x65, 0x6E, 0x74]) // "client"
    private static let bobParty   = Data([0x73, 0x65, 0x72, 0x76, 0x65, 0x72]) // "server"
    private static let derivedSecretKey = "gluco.v2.tandem.jpakeDerivedSecret"
    private static let serverNonceKey   = "gluco.v2.tandem.jpakeServerNonce"

    var pairingCode: String = ""
    var appInstanceId: UInt16 = 0

    private var privateKey1: G7U256?
    private var publicKey1: G7ECPoint?
    private var privateKey2: G7U256?
    private var publicKey2: G7ECPoint?

    private var clientRound1a = Data()
    private var clientRound1b = Data()
    private var serverRound1a = Data()
    private var serverRound1b = Data()

    private var remoteXm1: G7ECPoint?
    private var remoteXm2: G7ECPoint?

    private(set) var derivedSecret: Data?
    private(set) var serverNonce3: Data?
    private(set) var clientNonce4: Data?
    private(set) var isAuthenticated: Bool = false

    init(pairingCode: String = "") {
        self.pairingCode = pairingCode
        if let savedSecret = UserDefaults.standard.data(forKey: Self.derivedSecretKey), savedSecret.count == 32 {
            self.derivedSecret = savedSecret
        }
        if let savedNonce = UserDefaults.standard.data(forKey: Self.serverNonceKey), savedNonce.count == 8 {
            self.serverNonce3 = savedNonce
        }
    }

    var cleanPairingCode: String {
        pairingCode.uppercased().filter { $0.isLetter || $0.isNumber }
    }

    var isSixDigitMode: Bool {
        let c = cleanPairingCode
        return c.count == 6 && c.allSatisfy { $0.isNumber }
    }

    var isSixteenCharMode: Bool {
        cleanPairingCode.count == 16
    }

    var hasSavedSecret: Bool {
        (derivedSecret?.count ?? 0) == 32
    }

    var hasCredentialsOrSecret: Bool {
        hasSavedSecret || isSixDigitMode || isSixteenCharMode
    }

    private(set) var triedFastConfirmInSession: Bool = false

    func resetSession(clearPersistedSecret: Bool = false) {
        privateKey1 = nil
        publicKey1 = nil
        privateKey2 = nil
        publicKey2 = nil
        clientRound1a.removeAll()
        clientRound1b.removeAll()
        serverRound1a.removeAll()
        serverRound1b.removeAll()
        remoteXm1 = nil
        remoteXm2 = nil
        clientNonce4 = nil
        isAuthenticated = false
        triedFastConfirmInSession = false
        if clearPersistedSecret {
            derivedSecret = nil
            serverNonce3 = nil
            UserDefaults.standard.removeObject(forKey: Self.derivedSecretKey)
            UserDefaults.standard.removeObject(forKey: Self.serverNonceKey)
        }
    }

    // MARK: - 1. Start Auth Request (6-digit EC-JPAKE or 16-char CentralChallenge)

    func makeInitialAuthMessage() -> (opCode: UInt8, cargo: [UInt8], description: String)? {
        // 1. If we already have a confirmed 32-byte EC-JPAKE derivedSecret, use fast Jpake3SessionKeyRequest (opCode 38)
        if let secret = derivedSecret, secret.count == 32, !triedFastConfirmInSession {
            triedFastConfirmInSession = true
            return (38, [0x00, 0x00], "Tandem EC-JPAKE fast session key confirm (op 38)…")
        }
        // 2. Full 6-digit EC-JPAKE bootstrap (Jpake1aRequest = opCode 32)
        if isSixDigitMode {
            guard prepareECJPAKERound1() else { return nil }
            var cargo = [UInt8](repeating: 0, count: 167)
            cargo[0] = UInt8(appInstanceId & 0xFF)
            cargo[1] = UInt8((appInstanceId >> 8) & 0xFF)
            let bytes = [UInt8](clientRound1a.prefix(165))
            for i in 0..<bytes.count { cargo[2 + i] = bytes[i] }
            return (32, cargo, "Tandem 6-digit EC-JPAKE Round 1a sent (op 32)…")
        }
        // 3. 16-character CentralChallengeRequest (opCode 16 -> PumpChallengeRequest opCode 18)
        if isSixteenCharMode {
            var rand8 = [UInt8](repeating: 0, count: 8)
            _ = SecRandomCopyBytes(kSecRandomDefault, 8, &rand8)
            var cargo: [UInt8] = [0x01, 0x00]
            cargo.append(contentsOf: rand8)
            return (16, cargo, "Tandem 16-char CentralChallenge sent (op 16)…")
        }
        // Never send unsolicited CentralChallengeRequest (16) without a pairing code, as the pump
        // immediately closes the BLE connection if already authenticated or on JPAKE-only firmware.
        return nil
    }

    // MARK: - 2. Handle AUTHORIZATION (7B83FFF9) Response Messages

    func handleAuthorizationResponse(opCode: UInt8, cargo: [UInt8]) -> (nextOpCode: UInt8, nextCargo: [UInt8], statusText: String)? {
        switch opCode {
        case 17: // CentralChallengeResponse (30B: appInstanceId[2], centralChallengeHash[20], hmacKey[8])
            guard cargo.count >= 30 else { return nil }
            let appIdLo = cargo[0]
            let appIdHi = cargo[1]
            let hmacKey = Data(cargo[22..<30])
            let code = cleanPairingCode
            guard code.count == 16, let codeData = code.data(using: .utf8) else {
                return nil
            }
            let hash20 = Self.hmacSHA1(key: hmacKey, data: codeData)
            guard hash20.count == 20 else { return nil }
            var nextCargo: [UInt8] = [appIdLo, appIdHi]
            nextCargo.append(contentsOf: hash20)
            return (18, nextCargo, "Tandem PumpChallenge HMAC-SHA1 sent (op 18)…")

        case 19: // PumpChallengeResponse (3B: appInstanceId[2], success[1])
            guard cargo.count >= 3 else { return nil }
            if cargo[2] == 1 {
                isAuthenticated = true
                return (0, [], "Tandem 16-char BLE authentication succeeded!")
            } else {
                return (0, [], "Tandem rejected 16-char pairing code — check Pump Bluetooth Settings.")
            }

        case 33: // Jpake1aResponse (167B: appInstanceId[2], serverRound1a[165])
            guard cargo.count >= 2 else { return nil }
            var padded = cargo
            if padded.count < 167 {
                padded.append(contentsOf: [UInt8](repeating: 0, count: 167 - padded.count))
            }
            serverRound1a = Data(padded[2..<167])
            var nextCargo = [UInt8](repeating: 0, count: 167)
            nextCargo[0] = UInt8(appInstanceId & 0xFF)
            nextCargo[1] = UInt8((appInstanceId >> 8) & 0xFF)
            let bytes = [UInt8](clientRound1b.prefix(165))
            for i in 0..<bytes.count { nextCargo[2 + i] = bytes[i] }
            return (34, nextCargo, "Tandem EC-JPAKE Round 1b sent (op 34)…")

        case 35: // Jpake1bResponse (167B: appInstanceId[2], serverRound1b[165])
            guard cargo.count >= 2 else { return nil }
            var padded = cargo
            if padded.count < 167 {
                padded.append(contentsOf: [UInt8](repeating: 0, count: 167 - padded.count))
            }
            serverRound1b = Data(padded[2..<167])
            guard let round2 = processServerRound1AndMakeRound2() else {
                return (0, [], "Tandem EC-JPAKE Round 1 verification failed.")
            }
            var nextCargo = [UInt8](repeating: 0, count: 167)
            nextCargo[0] = UInt8(appInstanceId & 0xFF)
            nextCargo[1] = UInt8((appInstanceId >> 8) & 0xFF)
            let bytes = [UInt8](round2.prefix(165))
            for i in 0..<bytes.count { nextCargo[2 + i] = bytes[i] }
            return (36, nextCargo, "Tandem EC-JPAKE Round 2 sent (op 36)…")

        case 37: // Jpake2Response (170B: appInstanceId[2], curveHeader[3]=03 00 17, serverRound2[165])
            guard cargo.count >= 5 else { return nil }
            var padded = cargo
            if padded.count < 170 {
                padded.append(contentsOf: [UInt8](repeating: 0, count: 170 - padded.count))
            }
            let serverR2 = Data(padded[2..<170])
            guard processServerRound2AndDeriveSecret(serverR2) else {
                return (0, [], "Tandem EC-JPAKE Round 2 failed — check 6-digit pairing code!")
            }
            return (38, [0x00, 0x00], "Tandem EC-JPAKE Session Key request sent (op 38)…")

        case 39: // Jpake3SessionKeyResponse (18B: appInstanceId[2], nonce[8], reserved[8])
            guard cargo.count >= 10, let secret = derivedSecret, secret.count == 32 else { return nil }
            let nonce3 = Data(cargo[2..<10])
            self.serverNonce3 = nonce3
            var cNonce = [UInt8](repeating: 0, count: 8)
            _ = SecRandomCopyBytes(kSecRandomDefault, 8, &cNonce)
            let clientNonceData = Data(cNonce)
            self.clientNonce4 = clientNonceData

            let hkdfKey = Self.hkdfBuild(nonce: nonce3, keyMaterial: secret)
            let digest = Self.hmacSHA256(key: hkdfKey, data: clientNonceData)
            var nextCargo = [UInt8](repeating: 0, count: 50)
            nextCargo[0] = UInt8(appInstanceId & 0xFF)
            nextCargo[1] = UInt8((appInstanceId >> 8) & 0xFF)
            for i in 0..<8 { nextCargo[2 + i] = cNonce[i] }
            // bytes 10..<18 are 8 reserved zero bytes
            let dBytes = [UInt8](digest.prefix(32))
            for i in 0..<dBytes.count { nextCargo[18 + i] = dBytes[i] }
            return (40, nextCargo, "Tandem EC-JPAKE Key Confirmation sent (op 40)…")

        case 41: // Jpake4KeyConfirmationResponse (50B: appInstanceId[2], serverNonce4[8], reserved[8], hashDigest[32])
            guard cargo.count >= 50,
                  let secret = derivedSecret,
                  let nonce3 = serverNonce3 else { return nil }
            let serverNonce4 = Data(cargo[2..<10])
            let serverDigest = Data(cargo[18..<50])
            let hkdfKey = Self.hkdfBuild(nonce: nonce3, keyMaterial: secret)
            let expected = Self.hmacSHA256(key: hkdfKey, data: serverNonce4)
            if expected == serverDigest {
                isAuthenticated = true
                UserDefaults.standard.set(secret, forKey: Self.derivedSecretKey)
                UserDefaults.standard.set(nonce3, forKey: Self.serverNonceKey)
                return (0, [], "Tandem 6-digit EC-JPAKE pairing complete!")
            } else {
                resetSession(clearPersistedSecret: true)
                return (0, [], "Tandem EC-JPAKE confirmation mismatch — re-enter 6-digit code.")
            }

        default:
            return nil
        }
    }

    // MARK: - mbedTLS EC-JPAKE (165-Byte TLS Format) Primitives

    private func prepareECJPAKERound1() -> Bool {
        guard let kp1 = G7ECPoint.generateKeyPair(),
              let kp2 = G7ECPoint.generateKeyPair(),
              let r1a = makeTLSJpakeKeyShare(privateKey: kp1.privateKey, publicKey: kp1.publicKey, base: .generator, party: Self.aliceParty),
              let r1b = makeTLSJpakeKeyShare(privateKey: kp2.privateKey, publicKey: kp2.publicKey, base: .generator, party: Self.aliceParty) else {
            return false
        }
        privateKey1 = kp1.privateKey
        publicKey1 = kp1.publicKey
        privateKey2 = kp2.privateKey
        publicKey2 = kp2.publicKey
        clientRound1a = r1a
        clientRound1b = r1b
        return true
    }

    private func processServerRound1AndMakeRound2() -> Data? {
        var combined = Data()
        combined.append(serverRound1a)
        combined.append(serverRound1b)
        var offset = 0
        guard let share1 = parseTLSJpakeKeyShare(combined, offset: &offset),
              validateTLSZeroKnowledge(share1, base: .generator, party: Self.bobParty),
              let share2 = parseTLSJpakeKeyShare(combined, offset: &offset),
              validateTLSZeroKnowledge(share2, base: .generator, party: Self.bobParty),
              let pub1 = publicKey1, let priv2 = privateKey2 else {
            return nil
        }
        remoteXm1 = share1.publicKey
        remoteXm2 = share2.publicKey

        guard let cleanData = cleanPairingCode.data(using: .utf8), !cleanData.isEmpty else { return nil }
        let pwScalar = G7U256(bigEndianBytes: cleanData)
        let x2s = G7U256.modMul(priv2, pwScalar, .N)

        guard let sum1 = G7ECPoint.add(pub1, share1.publicKey),
              let baseG = G7ECPoint.add(sum1, share2.publicKey),
              let localPub2 = G7ECPoint.multiply(baseG, scalar: x2s),
              let round2Data = makeTLSJpakeKeyShare(privateKey: x2s, publicKey: localPub2, base: baseG, party: Self.aliceParty) else {
            return nil
        }
        return round2Data
    }

    private func processServerRound2AndDeriveSecret(_ data: Data) -> Bool {
        var offset = 0
        let bytes = [UInt8](data)
        // Skip optional 3-byte TLS curve identifier (0x03, 0x00, 0x17)
        if bytes.count >= 3 && bytes[0] == 0x03 && bytes[1] == 0x00 && bytes[2] == 0x17 {
            offset = 3
        }
        guard let shareS = parseTLSJpakeKeyShare(data, offset: &offset),
              let pub1 = publicKey1, let pub2 = publicKey2, let priv2 = privateKey2,
              let rXm1 = remoteXm1, let rXm2 = remoteXm2,
              let sumAB = G7ECPoint.add(pub1, pub2),
              let baseBob = G7ECPoint.add(sumAB, rXm1),
              validateTLSZeroKnowledge(shareS, base: baseBob, party: Self.bobParty),
              let cleanData = cleanPairingCode.data(using: .utf8), !cleanData.isEmpty else {
            return false
        }
        let pwScalar = G7U256(bigEndianBytes: cleanData)
        let x2s = G7U256.modMul(priv2, pwScalar, .N)
        guard let subPt = G7ECPoint.multiply(rXm2, scalar: x2s),
              let diffPt = G7ECPoint.subtract(shareS.publicKey, subPt),
              let keyPt = G7ECPoint.multiply(diffPt, scalar: priv2) else {
            return false
        }
        self.derivedSecret = Data(SHA256.hash(data: keyPt.x.bigEndianData))
        return true
    }

    private func makeTLSJpakeKeyShare(privateKey: G7U256, publicKey: G7ECPoint, base: G7ECPoint, party: Data) -> Data? {
        let v = G7ECPoint.randomScalarModN()
        guard let proofPt = G7ECPoint.multiply(base, scalar: v) else { return nil }
        let h = tlsZKHash(base: base, gv: proofPt, pub: publicKey, party: party)
        let prod = G7U256.modMul(h, privateKey, .N)
        let r = G7U256.modSub(v, prod, .N)

        var out = Data(capacity: 165)
        out.append(0x41)
        out.append(0x04)
        out.append(publicKey.raw64Data)
        out.append(0x41)
        out.append(0x04)
        out.append(proofPt.raw64Data)
        out.append(0x20)
        out.append(r.bigEndianData)
        return out
    }

    private func parseTLSJpakeKeyShare(_ data: Data, offset: inout Int) -> DexcomG7NativeAuthenticator.PakePacket? {
        let bytes = [UInt8](data)
        guard offset + 2 <= bytes.count else { return nil }
        let pubLen = Int(bytes[offset])
        offset += 1
        guard pubLen == 65, offset + pubLen <= bytes.count, bytes[offset] == 0x04 else { return nil }
        let pubData = Data(bytes[(offset + 1)..<(offset + 65)])
        offset += 65

        guard offset + 2 <= bytes.count else { return nil }
        let vLen = Int(bytes[offset])
        offset += 1
        guard vLen == 65, offset + vLen <= bytes.count, bytes[offset] == 0x04 else { return nil }
        let vData = Data(bytes[(offset + 1)..<(offset + 65)])
        offset += 65

        guard offset + 1 <= bytes.count else { return nil }
        let rLen = Int(bytes[offset])
        offset += 1
        guard rLen > 0 && rLen <= 32, offset + rLen <= bytes.count else { return nil }
        let rData = Data(bytes[offset..<(offset + rLen)])
        offset += rLen

        guard let pubPt = G7ECPoint(raw64Bytes: pubData),
              let proofPt = G7ECPoint(raw64Bytes: vData) else { return nil }
        let scalar = G7U256(bigEndianBytes: rData)
        return DexcomG7NativeAuthenticator.PakePacket(publicKey: pubPt, proofPoint: proofPt, proofScalar: scalar)
    }

    private func tlsZKHash(base: G7ECPoint, gv: G7ECPoint, pub: G7ECPoint, party: Data) -> G7U256 {
        var input = Data()
        func appendField(_ field: Data) {
            var beLen = UInt32(field.count).bigEndian
            withUnsafeBytes(of: &beLen) { input.append(contentsOf: $0) }
            input.append(field)
        }
        func uncompressed(_ pt: G7ECPoint) -> Data {
            var d = Data([0x04])
            d.append(pt.raw64Data)
            return d
        }
        appendField(uncompressed(base))
        appendField(uncompressed(gv))
        appendField(uncompressed(pub))
        appendField(party)
        let digest = Data(SHA256.hash(data: input))
        return G7U256.modReduce(G7U256(bigEndianBytes: digest), .N)
    }

    private func validateTLSZeroKnowledge(_ pkt: DexcomG7NativeAuthenticator.PakePacket, base: G7ECPoint, party: Data) -> Bool {
        let h = tlsZKHash(base: base, gv: pkt.proofPoint, pub: pkt.publicKey, party: party)
        guard let left = G7ECPoint.multiply(base, scalar: pkt.proofScalar),
              let right = G7ECPoint.multiply(pkt.publicKey, scalar: h),
              let combined = G7ECPoint.add(left, right) else {
            return false
        }
        return combined == pkt.proofPoint
    }

    // MARK: - Crypto Helpers (HMAC-SHA1, HMAC-SHA256, HKDF)

    static func hmacSHA1(key: Data, data: Data) -> Data {
        var mac = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))
        key.withUnsafeBytes { keyPtr in
            data.withUnsafeBytes { dataPtr in
                CCHmac(
                    CCHmacAlgorithm(kCCHmacAlgSHA1),
                    keyPtr.baseAddress, key.count,
                    dataPtr.baseAddress, data.count,
                    &mac
                )
            }
        }
        return Data(mac)
    }

    static func hmacSHA256(key: Data, data: Data) -> Data {
        let symKey = SymmetricKey(data: key)
        let code = HMAC<SHA256>.authenticationCode(for: data, using: symKey)
        return Data(code)
    }

    static func hkdfBuild(nonce: Data, keyMaterial: Data) -> Data {
        let prk = hmacSHA256(key: nonce, data: keyMaterial)
        return hmacSHA256(key: prk, data: Data([0x01]))
    }
}
