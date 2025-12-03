// This is a generated file - do not edit.
//
// Generated from psi.proto.

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

@$core.Deprecated('Use pingReqDescriptor instead')
const PingReq$json = {
  '1': 'PingReq',
  '2': [
    {'1': 'msg', '3': 1, '4': 1, '5': 9, '10': 'msg'},
  ],
};

/// Descriptor for `PingReq`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List pingReqDescriptor =
    $convert.base64Decode('CgdQaW5nUmVxEhAKA21zZxgBIAEoCVIDbXNn');

@$core.Deprecated('Use pingRespDescriptor instead')
const PingResp$json = {
  '1': 'PingResp',
  '2': [
    {'1': 'msg', '3': 1, '4': 1, '5': 9, '10': 'msg'},
  ],
};

/// Descriptor for `PingResp`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List pingRespDescriptor =
    $convert.base64Decode('CghQaW5nUmVzcBIQCgNtc2cYASABKAlSA21zZw==');

@$core.Deprecated('Use keyExchangeReqDescriptor instead')
const KeyExchangeReq$json = {
  '1': 'KeyExchangeReq',
  '2': [
    {'1': 'keys', '3': 1, '4': 3, '5': 12, '10': 'keys'},
  ],
};

/// Descriptor for `KeyExchangeReq`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List keyExchangeReqDescriptor =
    $convert.base64Decode('Cg5LZXlFeGNoYW5nZVJlcRISCgRrZXlzGAEgAygMUgRrZXlz');

@$core.Deprecated('Use keyExchangeRespDescriptor instead')
const KeyExchangeResp$json = {
  '1': 'KeyExchangeResp',
  '2': [
    {'1': 'keys', '3': 1, '4': 3, '5': 12, '10': 'keys'},
  ],
};

/// Descriptor for `KeyExchangeResp`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List keyExchangeRespDescriptor = $convert
    .base64Decode('Cg9LZXlFeGNoYW5nZVJlc3ASEgoEa2V5cxgBIAMoDFIEa2V5cw==');
