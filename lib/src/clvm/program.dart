import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:chia_utils/src/clvm/bytes.dart';
import 'package:chia_utils/src/clvm/instructions.dart';
import 'package:chia_utils/src/clvm/ir.dart';
import 'package:chia_utils/src/clvm/keywords.dart';
import 'package:chia_utils/src/clvm/parser.dart';
import 'package:chia_utils/src/clvm/printable.dart';
import 'package:crypto/crypto.dart';
import 'package:hex/hex.dart';
import 'package:quiver/core.dart';
import 'package:path/path.dart' as path;

class Output {
  final Program program;
  final BigInt cost;
  Output(this.program, this.cost);
}

class RunOptions {
  final BigInt? maxCost;
  final bool strict;
  RunOptions({this.maxCost, bool? strict}) : strict = strict ?? false;
}

typedef Validator = bool Function(Program);

class Program {
  List<Program>? _cons;
  Uint8List? _atom;
  Position? position;

  static int cost = 11000000000;
  static Program nil = Program.fromBytes([]);

  @override
  bool operator ==(Object other) =>
      other is Program &&
      isCons == other.isCons &&
      (isCons
          ? first() == other.first() && rest() == other.rest()
          : toBigInt() == other.toBigInt());

  @override
  int get hashCode =>
      isCons ? hash2(first().hashCode, rest().hashCode) : toBigInt().hashCode;

  bool get isNull => isAtom && atom.isEmpty;
  bool get isAtom => _atom != null;
  bool get isCons => _cons != null;
  Uint8List get atom => _atom!;
  List<Program> get cons => _cons!;
  String get positionSuffix => position == null ? '' : ' at $position';

  Program.cons(Program left, Program right) : _cons = [left, right];
  Program.fromBytes(List<int> atom) : _atom = Uint8List.fromList(atom);
  Program.fromHex(String hex)
      : _atom = Uint8List.fromList(HexDecoder().convert(hex));
  Program.fromBool(bool value) : _atom = Uint8List.fromList(value ? [1] : []);
  Program.fromInt(int number) : _atom = encodeInt(number);
  Program.fromBigInt(BigInt number) : _atom = encodeBigInt(number);
  Program.fromString(String text)
      : _atom = Uint8List.fromList(utf8.encode(text));

  factory Program.list(List<Program> items) {
    var result = Program.nil;
    for (var i = items.length - 1; i >= 0; i--) {
      result = Program.cons(items[i], result);
    }
    return result;
  }

  factory Program.parse(String source) {
    var stream = tokenStream(source);
    var iterator = stream.iterator;
    if (iterator.moveNext()) {
      return tokenizeExpr(source, iterator);
    } else {
      throw StateError('Unexpected end of source.');
    }
  }

  // TODO: dont want to keep reloading this every time
  factory Program.deserializeHexFile(String pathToFile) {
    var filePath = path.join(path.current, pathToFile);
    filePath = path.normalize(filePath);
    final lines = File(filePath).readAsLinesSync();

    final nonEmptyLines = lines.where((line) => line.isNotEmpty).toList();
    
    if (nonEmptyLines.length != 1) {
      throw Exception('Invalid file input: Should include one line of hex');
    }

    return Program.deserializeHex(nonEmptyLines[0]);
  }

  factory Program.deserialize(List<int> source) {
    var iterator = source.iterator;
    if (iterator.moveNext()) {
      return deserialize(iterator);
    } else {
      throw StateError('Unexpected end of source.');
    }
  }

  factory Program.deserializeHex(String source) =>
      Program.deserialize(HexDecoder().convert(source));

  Output run(Program args, {RunOptions? options}) {
    options ??= RunOptions();
    var instructions = <dynamic>[eval];
    var stack = [Program.cons(this, args)];
    var cost = BigInt.zero;
    while (instructions.isNotEmpty) {
      dynamic  instruction = instructions.removeLast();
      cost += instruction(instructions, stack, options) as BigInt;
      if (options.maxCost != null && cost > options.maxCost!) {
        throw StateError(
            'Exceeded cost of ${options.maxCost}${stack[stack.length - 1].positionSuffix}.');
      }
    }
    return Output(stack[stack.length - 1], cost);
  }

  Program curry(List<Program> args) {
    var current = Program.fromBigInt(keywords['q']!);
    for (var argument in args.reversed) {
      current = Program.cons(
          Program.fromBigInt(keywords['c']!),
          Program.cons(
              Program.cons(Program.fromBigInt(keywords['q']!), argument),
              Program.cons(current, Program.nil)));
    }
    return Program.parse('(a (q . ${toString()}) ${current.toString()})');
  }

  Program first() {
    if (isAtom) {
      throw StateError('Cannot access first of ${toString()}$positionSuffix.');
    }
    return cons[0];
  }

  Program rest() {
    if (isAtom) {
      throw StateError('Cannot access rest of ${toString()}$positionSuffix.');
    }
    return cons[1];
  }

  Uint8List hash() {
    if (isAtom) {
      return Uint8List.fromList(sha256.convert([1] + atom.toList()).bytes);
    } else {
      return Uint8List.fromList(sha256
          .convert([2] + cons[0].hash().toList() + cons[1].hash().toList())
          .bytes);
    }
  }

  String serializeHex() => HexEncoder().convert(serialize());

  Uint8List serialize() {
    if (isAtom) {
      if (atom.isEmpty) {
        return Uint8List.fromList([0x80]);
      } else if (atom.length == 1 && atom[0] <= 0x7f) {
        return Uint8List.fromList([atom[0]]);
      } else {
        var size = atom.length;
        List<int> result = [];
        if (size < 0x40) {
          result.add(0x80 | size);
        } else if (size < 0x2000) {
          result.add(0xC0 | (size >> 8));
          result.add((size >> 0) & 0xFF);
        } else if (size < 0x100000) {
          result.add(0xE0 | (size >> 16));
          result.add((size >> 8) & 0xFF);
          result.add((size >> 0) & 0xFF);
        } else if (size < 0x8000000) {
          result.add(0xF0 | (size >> 24));
          result.add((size >> 16) & 0xFF);
          result.add((size >> 8) & 0xFF);
          result.add((size >> 0) & 0xFF);
        } else if (size < 0x400000000) {
          result.add(0xF8 | (size >> 32));
          result.add((size >> 24) & 0xFF);
          result.add((size >> 16) & 0xFF);
          result.add((size >> 8) & 0xFF);
          result.add((size >> 0) & 0xFF);
        } else {
          throw RangeError(
              'Cannot serialize ${toString()} as it is 17,179,869,184 or more bytes in size$positionSuffix.');
        }
        result.addAll(atom);
        return Uint8List.fromList(result);
      }
    } else {
      var result = [0xff];
      result.addAll(cons[0].serialize());
      result.addAll(cons[1].serialize());
      return Uint8List.fromList(result);
    }
  }

  List<Program> toList(
      {int? min,
      int? max,
      int? size,
      String? suffix,
      Validator? validator,
      String? type}) {
    List<Program> result = [];
    var current = this;
    while (current.isCons) {
      var item = current.first();
      if (validator != null && !validator(item)) {
        throw ArgumentError(
            'Expected type $type for argument ${result.length + 1}${suffix != null ? ' $suffix' : ''}${item.positionSuffix}.');
      }
      result.add(item);
      current = current.rest();
    }
    if (size != null && result.length != size) {
      throw ArgumentError(
          'Expected $size arguments${suffix != null ? ' $suffix' : ''}$positionSuffix.');
    } else if (min != null && result.length < min) {
      throw ArgumentError(
          'Expected at least $min arguments${suffix != null ? ' $suffix' : ''}$positionSuffix.');
    } else if (max != null && result.length > max) {
      throw ArgumentError(
          'Expected at most $max arguments${suffix != null ? ' $suffix' : ''}$positionSuffix.');
    }
    return result;
  }

  List<Program> toAtomList({int? min, int? max, int? size, String? suffix}) {
    return toList(
        min: min,
        max: max,
        size: size,
        suffix: suffix,
        validator: (arg) => arg.isAtom,
        type: 'atom');
  }

  List<bool> toBoolList({int? min, int? max, int? size, String? suffix}) {
    return toList(
            min: min,
            max: max,
            size: size,
            suffix: suffix,
            validator: (arg) => arg.isAtom,
            type: 'boolean')
        .map((arg) => !arg.isNull)
        .toList();
  }

  List<Program> toConsList({int? min, int? max, int? size, String? suffix}) {
    return toList(
        min: min,
        max: max,
        size: size,
        suffix: suffix,
        validator: (arg) => arg.isCons,
        type: 'cons');
  }

  List<int> toIntList({int? min, int? max, int? size, String? suffix}) {
    return toList(
            min: min,
            max: max,
            size: size,
            suffix: suffix,
            validator: (arg) => arg.isAtom,
            type: 'int')
        .map((arg) => arg.toInt())
        .toList();
  }

  List<BigInt> toBigIntList({int? min, int? max, int? size, String? suffix}) {
    return toList(
            min: min,
            max: max,
            size: size,
            suffix: suffix,
            validator: (arg) => arg.isAtom,
            type: 'int')
        .map((arg) => arg.toBigInt())
        .toList();
  }

  String toHex() {
    if (isCons) {
      throw StateError(
          'Cannot convert ${toString()} to hex format$positionSuffix.');
    } else {
      return HexEncoder().convert(atom);
    }
  }

  bool toBool() {
    if (isCons) {
      throw StateError(
          'Cannot convert ${toString()} to boolean format$positionSuffix.');
    } else {
      return !isNull;
    }
  }

  int toInt() {
    if (isCons) {
      throw StateError(
          'Cannot convert ${toString()} to int format$positionSuffix.');
    } else {
      return decodeInt(atom);
    }
  }

  BigInt toBigInt() {
    if (isCons) {
      throw StateError('Cannot convert ${toString()} to bigint format.');
    } else {
      return decodeBigInt(atom);
    }
  }

  Program at(Position? position) {
    this.position = position;
    return this;
  }

  String toSource({bool? showKeywords}) {
    showKeywords ??= true;
    if (isAtom) {
      if (atom.isEmpty) {
        return '()';
      } else if (atom.length > 2) {
        try {
          var string = utf8.decode(atom);
          for (var i = 0; i < string.length; i++) {
            if (!printable.contains(string[i])) {
              return '0x' + toHex();
            }
          }
          if (string.contains('"') && string.contains("'")) {
            return '0x' + toHex();
          }
          var quote = string.contains('"') ? "'" : '"';
          return quote + string + quote;
        } catch (e) {
          return '0x' + toHex();
        }
      } else if (bytesEqual(encodeInt(decodeInt(atom)), atom)) {
        return decodeInt(atom).toString();
      } else {
        return '0x' + toHex();
      }
    } else {
      var result = '(';
      if (showKeywords) {
        try {
          var value = cons[0].toBigInt();
          result += keywords.keys.firstWhere((key) => keywords[key] == value);
        } catch (e) {
          result += cons[0].toSource(showKeywords: showKeywords);
        }
      } else {
        result += cons[0].toSource(showKeywords: showKeywords);
      }
      var current = cons[1];
      while (current.isCons) {
        result += ' ${current.cons[0].toSource(showKeywords: showKeywords)}';
        current = current.cons[1];
      }
      result += (current.isNull
              ? ''
              : ' . ${current.toSource(showKeywords: showKeywords)}') +
          ')';
      return result;
    }
  }

  @override
  String toString() => toSource();
}
