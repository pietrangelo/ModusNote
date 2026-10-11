import 'dart:convert';
import 'dart:typed_data';

import 'package:identity_cryptography/identity_cryptography.dart';
import 'package:identity_cryptography_adapters/identity_cryptography_adapters.dart';
import 'package:sodium/sodium_sumo.dart';

late SodiumSumo sodium;

Future<void> initSodium() async => sodium = await SodiumSumoInit.init();

PasswordSecret password(String text) => SodiumPasswordSecret.fromUtf8Bytes(
  sodium,
  Uint8List.fromList(utf8.encode(text)),
);

Uint8List utf8Bytes(String text) => Uint8List.fromList(utf8.encode(text));
