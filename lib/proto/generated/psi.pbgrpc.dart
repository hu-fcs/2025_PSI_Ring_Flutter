// This is a generated file - do not edit.
//
// Generated from psi.proto.

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

import 'psi.pb.dart' as $0;

export 'psi.pb.dart';

@$pb.GrpcServiceName('psi.PsiService')
class PsiServiceClient extends $grpc.Client {
  /// The hostname for this service.
  static const $core.String defaultHost = '';

  /// OAuth scopes needed for the client.
  static const $core.List<$core.String> oauthScopes = [
    '',
  ];

  PsiServiceClient(super.channel, {super.options, super.interceptors});

  $grpc.ResponseFuture<$0.PingResp> ping(
    $0.PingReq request, {
    $grpc.CallOptions? options,
  }) {
    return $createUnaryCall(_$ping, request, options: options);
  }

  // method descriptors

  static final _$ping = $grpc.ClientMethod<$0.PingReq, $0.PingResp>(
      '/psi.PsiService/Ping',
      ($0.PingReq value) => value.writeToBuffer(),
      $0.PingResp.fromBuffer);
}

@$pb.GrpcServiceName('psi.PsiService')
abstract class PsiServiceBase extends $grpc.Service {
  $core.String get $name => 'psi.PsiService';

  PsiServiceBase() {
    $addMethod($grpc.ServiceMethod<$0.PingReq, $0.PingResp>(
        'Ping',
        ping_Pre,
        false,
        false,
        ($core.List<$core.int> value) => $0.PingReq.fromBuffer(value),
        ($0.PingResp value) => value.writeToBuffer()));
  }

  $async.Future<$0.PingResp> ping_Pre(
      $grpc.ServiceCall $call, $async.Future<$0.PingReq> $request) async {
    return ping($call, await $request);
  }

  $async.Future<$0.PingResp> ping($grpc.ServiceCall call, $0.PingReq request);
}
