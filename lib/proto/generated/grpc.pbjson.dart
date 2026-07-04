// This is a generated file - do not edit.
//
// Generated from grpc.proto.

// @dart = 3.3

// ignore_for_file: annotate_overrides, camel_case_types, comment_references
// ignore_for_file: constant_identifier_names
// ignore_for_file: curly_braces_in_flow_control_structures
// ignore_for_file: deprecated_member_use_from_same_package, library_prefixes
// ignore_for_file: non_constant_identifier_names, prefer_relative_imports
// ignore_for_file: unused_import

import 'dart:convert' as $convert;
import 'dart:core' as $core;
import 'dart:typed_data' as $typed_data;

@$core.Deprecated('Use keyExchangeReqDescriptor instead')
const KeyExchangeReq$json = {
  '1': 'KeyExchangeReq',
  '2': [
    {'1': 'enc_keys', '3': 1, '4': 3, '5': 12, '10': 'encKeys'},
  ],
};

/// Descriptor for `KeyExchangeReq`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List keyExchangeReqDescriptor = $convert.base64Decode(
    'Cg5LZXlFeGNoYW5nZVJlcRIZCghlbmNfa2V5cxgBIAMoDFIHZW5jS2V5cw==');

@$core.Deprecated('Use keyExchangeRespDescriptor instead')
const KeyExchangeResp$json = {
  '1': 'KeyExchangeResp',
  '2': [
    {'1': 'server_enc_keys', '3': 1, '4': 3, '5': 12, '10': 'serverEncKeys'},
    {
      '1': 'client_reenc_keys',
      '3': 2,
      '4': 3,
      '5': 12,
      '10': 'clientReencKeys'
    },
  ],
};

/// Descriptor for `KeyExchangeResp`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List keyExchangeRespDescriptor = $convert.base64Decode(
    'Cg9LZXlFeGNoYW5nZVJlc3ASJgoPc2VydmVyX2VuY19rZXlzGAEgAygMUg1zZXJ2ZXJFbmNLZX'
    'lzEioKEWNsaWVudF9yZWVuY19rZXlzGAIgAygMUg9jbGllbnRSZWVuY0tleXM=');

@$core.Deprecated('Use clientFinalReqDescriptor instead')
const ClientFinalReq$json = {
  '1': 'ClientFinalReq',
  '2': [
    {
      '1': 'client_reenc_server_keys',
      '3': 1,
      '4': 3,
      '5': 12,
      '10': 'clientReencServerKeys'
    },
  ],
};

/// Descriptor for `ClientFinalReq`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List clientFinalReqDescriptor = $convert.base64Decode(
    'Cg5DbGllbnRGaW5hbFJlcRI3ChhjbGllbnRfcmVlbmNfc2VydmVyX2tleXMYASADKAxSFWNsaW'
    'VudFJlZW5jU2VydmVyS2V5cw==');

@$core.Deprecated('Use psiDoneDescriptor instead')
const PsiDone$json = {
  '1': 'PsiDone',
};

/// Descriptor for `PsiDone`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List psiDoneDescriptor =
    $convert.base64Decode('CgdQc2lEb25l');

@$core.Deprecated('Use clientChallengeDescriptor instead')
const ClientChallenge$json = {
  '1': 'ClientChallenge',
  '2': [
    {'1': 'challenge_c', '3': 1, '4': 1, '5': 12, '10': 'challengeC'},
  ],
};

/// Descriptor for `ClientChallenge`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List clientChallengeDescriptor = $convert.base64Decode(
    'Cg9DbGllbnRDaGFsbGVuZ2USHwoLY2hhbGxlbmdlX2MYASABKAxSCmNoYWxsZW5nZUM=');

@$core.Deprecated('Use serverChallengeDescriptor instead')
const ServerChallenge$json = {
  '1': 'ServerChallenge',
  '2': [
    {'1': 'challenge_s', '3': 1, '4': 1, '5': 12, '10': 'challengeS'},
  ],
};

/// Descriptor for `ServerChallenge`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List serverChallengeDescriptor = $convert.base64Decode(
    'Cg9TZXJ2ZXJDaGFsbGVuZ2USHwoLY2hhbGxlbmdlX3MYASABKAxSCmNoYWxsZW5nZVM=');

@$core.Deprecated('Use ringSignatureReqDescriptor instead')
const RingSignatureReq$json = {
  '1': 'RingSignatureReq',
  '2': [
    {
      '1': 'signature_for_server',
      '3': 1,
      '4': 1,
      '5': 12,
      '10': 'signatureForServer'
    },
  ],
};

/// Descriptor for `RingSignatureReq`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List ringSignatureReqDescriptor = $convert.base64Decode(
    'ChBSaW5nU2lnbmF0dXJlUmVxEjAKFHNpZ25hdHVyZV9mb3Jfc2VydmVyGAEgASgMUhJzaWduYX'
    'R1cmVGb3JTZXJ2ZXI=');

@$core.Deprecated('Use ringSignatureRespDescriptor instead')
const RingSignatureResp$json = {
  '1': 'RingSignatureResp',
  '2': [
    {
      '1': 'signature_for_client',
      '3': 1,
      '4': 1,
      '5': 12,
      '10': 'signatureForClient'
    },
  ],
};

/// Descriptor for `RingSignatureResp`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List ringSignatureRespDescriptor = $convert.base64Decode(
    'ChFSaW5nU2lnbmF0dXJlUmVzcBIwChRzaWduYXR1cmVfZm9yX2NsaWVudBgBIAEoDFISc2lnbm'
    'F0dXJlRm9yQ2xpZW50');
