import 'dart:convert';
import 'dart:typed_data';

import 'package:chia_utils/src/bls/ec/ec.dart';
import 'package:chia_utils/src/bls/ec/jacobian_point.dart';
import 'package:chia_utils/src/bls/hkdf.dart';
import 'package:chia_utils/src/clvm/bytes.dart';
import 'package:hex/hex.dart';
import 'package:meta/meta.dart';

@immutable
class PrivateKey {
  PrivateKey(this.value)
      : assert(
          value < defaultEc.n,
          'Private key must be less than ${defaultEc.n}',
        );

  factory PrivateKey.fromBytes(List<int> bytes) =>
      PrivateKey(bytesToBigInt(bytes, Endian.big) % defaultEc.n);

  factory PrivateKey.fromHex(String hex) =>
      PrivateKey.fromBytes(const HexDecoder().convert(hex));

  factory PrivateKey.fromSeed(List<int> seed) {
    const L = 48;
    final okm = extractExpand(
      L,
      seed + [0],
      utf8.encode('BLS-SIG-KEYGEN-SALT-'),
      [0, L],
    );
    return PrivateKey(bytesToBigInt(okm, Endian.big) % defaultEc.n);
  }

  factory PrivateKey.fromBigInt(BigInt n) => PrivateKey(n % defaultEc.n);

  factory PrivateKey.aggregate(List<PrivateKey> privateKeys) => PrivateKey(
        privateKeys.fold(
              BigInt.zero,
              (BigInt aggregate, privateKey) => aggregate + privateKey.value,
            ) %
            defaultEc.n,
      );

  final BigInt value;

  static const int size = 32;

  JacobianPoint getG1() => JacobianPoint.generateG1() * value;

  Uint8List toBytes() => bigIntToBytes(value, size, Endian.big);

  String toHex() => const HexEncoder().convert(toBytes());

  @override
  String toString() => 'PrivateKey(0x${toHex()})';

  @override
  bool operator ==(dynamic other) =>
      other is PrivateKey && value == other.value;

  @override
  int get hashCode => runtimeType.hashCode ^ value.hashCode;
}
