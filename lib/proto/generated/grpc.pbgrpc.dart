// This is a generated file - do not edit.
//
// Generated from grpc.proto.

// @dart = 3.3

// ignore_for_file: annotate_overrides, camel_case_types, comment_references
// ignore_for_file: constant_identifier_names
// ignore_for_file: curly_braces_in_flow_control_structures
// ignore_for_file: deprecated_member_use_from_same_package, library_prefixes
// ignore_for_file: non_constant_identifier_names, prefer_relative_imports

import 'dart:async' as $async;
import 'dart:core' as $core;

import 'package:grpc/service_api.dart' as $grpc;
import 'package:protobuf/protobuf.dart' as $pb;

import 'grpc.pb.dart' as $0;

export 'grpc.pb.dart';

@$pb.GrpcServiceName('grpc.GrpcService')
class GrpcServiceClient extends $grpc.Client {
  /// The hostname for this service.
  static const $core.String defaultHost = '';

  /// OAuth scopes needed for the client.
  static const $core.List<$core.String> oauthScopes = [
    '',
  ];

  GrpcServiceClient(super.channel, {super.options, super.interceptors});

  $grpc.ResponseFuture<$0.KeyExchangeResp> exchangeKeys(
    $0.KeyExchangeReq request, {
    $grpc.CallOptions? options,
  }) {
    return $createUnaryCall(_$exchangeKeys, request, options: options);
  }

  $grpc.ResponseFuture<$0.PsiDone> finalizePsi(
    $0.ClientFinalReq request, {
    $grpc.CallOptions? options,
  }) {
    return $createUnaryCall(_$finalizePsi, request, options: options);
  }

  // method descriptors

  static final _$exchangeKeys =
      $grpc.ClientMethod<$0.KeyExchangeReq, $0.KeyExchangeResp>(
          '/grpc.GrpcService/ExchangeKeys',
          ($0.KeyExchangeReq value) => value.writeToBuffer(),
          $0.KeyExchangeResp.fromBuffer);
  static final _$finalizePsi =
      $grpc.ClientMethod<$0.ClientFinalReq, $0.PsiDone>(
          '/grpc.GrpcService/FinalizePsi',
          ($0.ClientFinalReq value) => value.writeToBuffer(),
          $0.PsiDone.fromBuffer);
}

@$pb.GrpcServiceName('grpc.GrpcService')
abstract class GrpcServiceBase extends $grpc.Service {
  $core.String get $name => 'grpc.GrpcService';

  GrpcServiceBase() {
    $addMethod($grpc.ServiceMethod<$0.KeyExchangeReq, $0.KeyExchangeResp>(
        'ExchangeKeys',
        exchangeKeys_Pre,
        false,
        false,
        ($core.List<$core.int> value) => $0.KeyExchangeReq.fromBuffer(value),
        ($0.KeyExchangeResp value) => value.writeToBuffer()));
    $addMethod($grpc.ServiceMethod<$0.ClientFinalReq, $0.PsiDone>(
        'FinalizePsi',
        finalizePsi_Pre,
        false,
        false,
        ($core.List<$core.int> value) => $0.ClientFinalReq.fromBuffer(value),
        ($0.PsiDone value) => value.writeToBuffer()));
  }

  $async.Future<$0.KeyExchangeResp> exchangeKeys_Pre($grpc.ServiceCall $call,
      $async.Future<$0.KeyExchangeReq> $request) async {
    return exchangeKeys($call, await $request);
  }

  $async.Future<$0.KeyExchangeResp> exchangeKeys(
      $grpc.ServiceCall call, $0.KeyExchangeReq request);

  $async.Future<$0.PsiDone> finalizePsi_Pre($grpc.ServiceCall $call,
      $async.Future<$0.ClientFinalReq> $request) async {
    return finalizePsi($call, await $request);
  }

  $async.Future<$0.PsiDone> finalizePsi(
      $grpc.ServiceCall call, $0.ClientFinalReq request);
}
