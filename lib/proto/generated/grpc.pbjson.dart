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
