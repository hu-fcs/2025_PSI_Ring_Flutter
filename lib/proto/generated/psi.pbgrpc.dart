///
//  Generated code. Do not modify.
//  source: psi.proto
//
// @dart = 2.12
// ignore_for_file: annotate_overrides,camel_case_types,constant_identifier_names,directives_ordering,library_prefixes,non_constant_identifier_names,prefer_final_fields,return_of_invalid_type,unnecessary_const,unnecessary_import,unnecessary_this,unused_import,unused_shown_name

import 'dart:async' as $async;

import 'dart:core' as $core;

import 'package:grpc/service_api.dart' as $grpc;
import 'psi.pb.dart' as $0;
export 'psi.pb.dart';

class PsiServiceClient extends $grpc.Client {
  static final _$ping = $grpc.ClientMethod<$0.PingReq, $0.PingResp>(
      '/psi.PsiService/Ping',
      ($0.PingReq value) => value.writeToBuffer(),
      ($core.List<$core.int> value) => $0.PingResp.fromBuffer(value));

  PsiServiceClient($grpc.ClientChannel channel,
      {$grpc.CallOptions? options,
      $core.Iterable<$grpc.ClientInterceptor>? interceptors})
      : super(channel, options: options, interceptors: interceptors);

  $grpc.ResponseFuture<$0.PingResp> ping($0.PingReq request,
      {$grpc.CallOptions? options}) {
    return $createUnaryCall(_$ping, request, options: options);
  }
}

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
      $grpc.ServiceCall call, $async.Future<$0.PingReq> request) async {
    return ping(call, await request);
  }

  $async.Future<$0.PingResp> ping($grpc.ServiceCall call, $0.PingReq request);
}
