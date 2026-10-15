/// 纯 Dart 的 **AES-128-CBC + PKCS7** 解密（v2.54.0，中国移动掌厅抓取用）。
///
/// ## 为什么手写，而不是引依赖
///
/// 掌厅页面的接口响应是 **AES-128-CBC / PKCS7** 密文（key/IV 见
/// `cmcc_plan.dart` 的 `kCmccAesKey` / `kCmccAesIv`）。本工程现有依赖里
/// **没有可用的 AES 实现**：
/// - `crypto` 只做摘要（md5/sha/hmac），不含分组密码；
/// - `archive` 里那份 AES 在 `package:archive/src/...`（包内部实现，导入会触发
///   `implementation_imports` lint，而且它是给 zip 的 AES-256-CTR 用的，不是
///   CBC）；`pointycastle` 之类要新增依赖（用户明确要求不擅自加依赖）。
///
/// 所以这里手写**只需要解密方向**的最小实现（128 位密钥 / CBC / PKCS7 去填充），
/// 不写加密、不做 AES-192/256——用不到的东西不写，少写一行少一个 bug。
///
/// ## 正确性怎么保证
///
/// - 标准向量自证：FIPS-197 的 AES-128 单分组向量（见 `test/cmcc_aes_test.dart`）
///   钉死分组解密本身；CBC/PKCS7 另用**自造向量**（同一 key/IV 手工加密一段
///   JSON）钉死串联与去填充——**不使用任何真实运营商响应**；
/// - S 盒**运行时算**（乘法逆元 + 仿射变换），不手抄 256 个常量：抄错一个字节
///   是这类实现最典型的坑，算出来的值还能用"逆 S 盒自反"当场验证。
library;

import 'dart:typed_data';

/// AES 分组长度（字节）。
const int kAesBlockSize = 16;

/// AES-128 的密钥长度（字节）/ 轮数。
const int kAes128KeyBytes = 16;
const int _kRounds = 10;

/// 单个字节做 GF(2^8) 乘法（既约多项式 `x^8+x^4+x^3+x+1` = 0x11b）。
int gfMul(int a, int b) {
  var x = a & 0xff;
  var y = b & 0xff;
  var r = 0;
  while (y != 0) {
    if (y & 1 != 0) r ^= x;
    final hi = x & 0x80;
    x = (x << 1) & 0xff;
    if (hi != 0) x ^= 0x1b;
    y >>= 1;
  }
  return r & 0xff;
}

/// S 盒（运行时构造，见文件头说明）。
final Uint8List _sbox = _buildSBox();

/// 逆 S 盒（由 S 盒反查）。
final Uint8List _invSbox = _buildInvSBox(_sbox);

Uint8List _buildSBox() {
  final box = Uint8List(256);
  for (var x = 0; x < 256; x++) {
    // 乘法逆元（0 的逆元规定为 0）
    var inv = 0;
    if (x != 0) {
      for (var y = 1; y < 256; y++) {
        if (gfMul(x, y) == 1) {
          inv = y;
          break;
        }
      }
    }
    // 仿射变换：b ^ rotl(b,1) ^ rotl(b,2) ^ rotl(b,3) ^ rotl(b,4) ^ 0x63
    var b = inv;
    var v = b ^ 0x63;
    for (var i = 1; i <= 4; i++) {
      b = ((b << 1) | (b >> 7)) & 0xff;
      v ^= b;
    }
    box[x] = v & 0xff;
  }
  return box;
}

Uint8List _buildInvSBox(Uint8List sbox) {
  final inv = Uint8List(256);
  for (var i = 0; i < 256; i++) {
    inv[sbox[i]] = i;
  }
  return inv;
}

/// 把 16 字节密钥展开成 176 字节轮密钥（`w[0..10]`，每个 16 字节）。
Uint8List _expandKey(Uint8List key) {
  if (key.length != kAes128KeyBytes) {
    throw ArgumentError('AES-128 密钥必须是 16 字节，收到 ${key.length}');
  }
  final w = Uint8List(16 * (_kRounds + 1));
  w.setRange(0, 16, key);
  var rcon = 1;
  for (var i = 16; i < w.length; i += 4) {
    var t0 = w[i - 4], t1 = w[i - 3], t2 = w[i - 2], t3 = w[i - 1];
    if (i % 16 == 0) {
      // RotWord + SubWord + Rcon
      final tmp = t0;
      t0 = _sbox[t1] ^ rcon;
      t1 = _sbox[t2];
      t2 = _sbox[t3];
      t3 = _sbox[tmp];
      rcon = gfMul(rcon, 2);
    }
    final base = i - 16;
    w[i] = w[base] ^ t0;
    w[i + 1] = w[base + 1] ^ t1;
    w[i + 2] = w[base + 2] ^ t2;
    w[i + 3] = w[base + 3] ^ t3;
  }
  return w;
}

/// 解一个分组的**逆变换**（InvShiftRows → InvSubBytes → AddRoundKey(第 r 轮) → InvMixColumns）。
///
/// 传入的 `state` 是 16 字节就地状态（列优先：`state[r + 4c]`）。
void _invCipherRound(Uint8List state, Uint8List w, int round) {
  // InvShiftRows：第 r 行循环右移 r 位
  final rows = Uint8List.fromList(state);
  for (var r = 1; r < 4; r++) {
    for (var c = 0; c < 4; c++) {
      state[r + 4 * c] = rows[r + 4 * ((c - r) & 3)];
    }
  }
  // InvSubBytes
  for (var i = 0; i < 16; i++) {
    state[i] = _invSbox[state[i]];
  }
  // AddRoundKey
  final off = round * 16;
  for (var i = 0; i < 16; i++) {
    state[i] ^= w[off + i];
  }
  // InvMixColumns
  for (var c = 0; c < 4; c++) {
    final i = 4 * c;
    final a0 = state[i], a1 = state[i + 1], a2 = state[i + 2], a3 = state[i + 3];
    state[i] = gfMul(a0, 14) ^ gfMul(a1, 11) ^ gfMul(a2, 13) ^ gfMul(a3, 9);
    state[i + 1] = gfMul(a0, 9) ^ gfMul(a1, 14) ^ gfMul(a2, 11) ^ gfMul(a3, 13);
    state[i + 2] =
        gfMul(a0, 13) ^ gfMul(a1, 9) ^ gfMul(a2, 14) ^ gfMul(a3, 11);
    state[i + 3] =
        gfMul(a0, 11) ^ gfMul(a1, 13) ^ gfMul(a2, 9) ^ gfMul(a3, 14);
  }
}

/// 解一个 16 字节分组（ECB 单分组解密；CBC 的串联由 [aes128CbcDecrypt] 做）。
///
/// 单独暴露出来是为了能用 FIPS-197 的标准向量钉死**分组解密本身**
/// （CBC 出问题时分不清是分组算法错还是串联/填充错）。
Uint8List aes128DecryptBlock(Uint8List key, Uint8List block) {
  if (block.length != kAesBlockSize) {
    throw ArgumentError('分组必须是 16 字节，收到 ${block.length}');
  }
  return _decryptBlockWith(_expandKey(key), block);
}

/// AES-128-CBC 解密（**带 PKCS7 去填充**）。
///
/// [cipher] 长度必须是 16 的整数倍且非空，否则抛 [ArgumentError]（调用方
/// [decryptCmccPayload] 会先过 [looksLikeCipherHex]，这两层不重复）。
/// 去填充失败（填充字节不自洽，通常是 key/IV 不对或数据被截断）→ 抛
/// [FormatException]，让上层当成"解不开"，**不要**把半个结果当数据用。
Uint8List aes128CbcDecrypt(Uint8List key, Uint8List iv, Uint8List cipher) {
  if (iv.length != kAesBlockSize) {
    throw ArgumentError('CBC 的 IV 必须是 16 字节，收到 ${iv.length}');
  }
  if (cipher.isEmpty || cipher.length % kAesBlockSize != 0) {
    throw ArgumentError('密文长度必须是 16 的非零整数倍，收到 ${cipher.length}');
  }
  final w = _expandKey(key); // 展开一次，所有分组共用
  final out = Uint8List(cipher.length);
  var prev = iv;
  final block = Uint8List(16);
  for (var off = 0; off < cipher.length; off += 16) {
    block.setRange(0, 16, cipher, off);
    final plain = _decryptBlockWith(w, block);
    for (var i = 0; i < 16; i++) {
      out[off + i] = plain[i] ^ prev[i];
    }
    prev = Uint8List.fromList(cipher.sublist(off, off + 16));
  }
  return pkcs7Unpad(out);
}

/// 与 [aes128DecryptBlock] 同一算法，但复用已展开的轮密钥并**就地返回**。
Uint8List _decryptBlockWith(Uint8List w, Uint8List block) {
  final state = Uint8List.fromList(block);
  for (var i = 0; i < 16; i++) {
    state[i] ^= w[160 + i];
  }
  for (var round = _kRounds - 1; round >= 1; round--) {
    _invCipherRound(state, w, round);
  }
  final rows = Uint8List.fromList(state);
  for (var r = 1; r < 4; r++) {
    for (var c = 0; c < 4; c++) {
      state[r + 4 * c] = rows[r + 4 * ((c - r) & 3)];
    }
  }
  for (var i = 0; i < 16; i++) {
    state[i] = _invSbox[state[i]];
  }
  for (var i = 0; i < 16; i++) {
    state[i] ^= w[i];
  }
  return state;
}

/// PKCS7 去填充（填充字节必须 1..16 且尾部全等于它）。
Uint8List pkcs7Unpad(Uint8List data) {
  if (data.isEmpty) throw const FormatException('PKCS7：空数据');
  final pad = data[data.length - 1];
  if (pad < 1 || pad > kAesBlockSize || pad > data.length) {
    throw const FormatException('PKCS7：填充长度非法');
  }
  for (var i = data.length - pad; i < data.length; i++) {
    if (data[i] != pad) throw const FormatException('PKCS7：填充字节不一致');
  }
  return Uint8List.sublistView(data, 0, data.length - pad);
}

/// 只含 0-9a-f（大小写均可）的字符串才可能是 hex 密文。
final RegExp _hexOnly = RegExp(r'^[0-9a-fA-F]+$');

/// **"这条响应是不是密文"的判定规则**（两份独立开源实现一致，照抄）：
/// 去空白后长度 ≥ 32、长度是 32 的整数倍（=16 字节的整数倍）、且**全是 hex 字符**。
///
/// 不满足 → 按**明文 JSON** 处理（页面可能在某些分支直出 JSON，别硬解）。
bool looksLikeCipherHex(String body) {
  final s = body.trim();
  if (s.length < 32) return false;
  if (s.length % 32 != 0) return false;
  return _hexOnly.hasMatch(s);
}

/// hex 串 → 字节。
Uint8List hexToBytes(String hex) {
  final s = hex.trim();
  if (s.length.isOdd) throw const FormatException('hex 长度必须是偶数');
  final out = Uint8List(s.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    final b = int.tryParse(s.substring(i * 2, i * 2 + 2), radix: 16);
    if (b == null) throw const FormatException('hex 里有非法字符');
    out[i] = b;
  }
  return out;
}

/// 字节 → 小写 hex（测试与调试用；生产路径不回写密文）。
String bytesToHex(List<int> data) =>
    [for (final b in data) (b & 0xff).toRadixString(16).padLeft(2, '0')].join();
