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

  /// PSI
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

  $grpc.ResponseFuture<$0.ServerChallenge> exchangeChallenges(
    $0.ClientChallenge request, {
    $grpc.CallOptions? options,
  }) {
    return $createUnaryCall(_$exchangeChallenges, request, options: options);
  }

  $grpc.ResponseFuture<$0.RingSignatureResp> exchangeRingSignatures(
    $0.RingSignatureReq request, {
    $grpc.CallOptions? options,
  }) {
    return $createUnaryCall(_$exchangeRingSignatures, request,
        options: options);
  }

  /// 将来ニックネームの共有
  $grpc.ResponseFuture<$0.NicknameScheduleReqResp> exchangeNicknameSchedule(
    $0.NicknameScheduleReqResp request, {
    $grpc.CallOptions? options,
  }) {
    return $createUnaryCall(_$exchangeNicknameSchedule, request,
        options: options);
  }

  $grpc.ResponseFuture<$0.NicknameScheduleAckResp> exchangeNicknameScheduleAck(
    $0.NicknameScheduleAckReq request, {
    $grpc.CallOptions? options,
  }) {
    return $createUnaryCall(_$exchangeNicknameScheduleAck, request,
        options: options);
  }

  /// OOB (Out-of-band) 認証
  $grpc.ResponseFuture<$0.Empty> outOfBandAuth(
    $0.OutOfBandAuthReq request, {
    $grpc.CallOptions? options,
  }) {
    return $createUnaryCall(_$outOfBandAuth, request, options: options);
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
  static final _$exchangeChallenges =
      $grpc.ClientMethod<$0.ClientChallenge, $0.ServerChallenge>(
          '/grpc.GrpcService/ExchangeChallenges',
          ($0.ClientChallenge value) => value.writeToBuffer(),
          $0.ServerChallenge.fromBuffer);
  static final _$exchangeRingSignatures =
      $grpc.ClientMethod<$0.RingSignatureReq, $0.RingSignatureResp>(
          '/grpc.GrpcService/ExchangeRingSignatures',
          ($0.RingSignatureReq value) => value.writeToBuffer(),
          $0.RingSignatureResp.fromBuffer);
  static final _$exchangeNicknameSchedule = $grpc.ClientMethod<
          $0.NicknameScheduleReqResp, $0.NicknameScheduleReqResp>(
      '/grpc.GrpcService/ExchangeNicknameSchedule',
      ($0.NicknameScheduleReqResp value) => value.writeToBuffer(),
      $0.NicknameScheduleReqResp.fromBuffer);
  static final _$exchangeNicknameScheduleAck =
      $grpc.ClientMethod<$0.NicknameScheduleAckReq, $0.NicknameScheduleAckResp>(
          '/grpc.GrpcService/ExchangeNicknameScheduleAck',
          ($0.NicknameScheduleAckReq value) => value.writeToBuffer(),
          $0.NicknameScheduleAckResp.fromBuffer);
  static final _$outOfBandAuth =
      $grpc.ClientMethod<$0.OutOfBandAuthReq, $0.Empty>(
          '/grpc.GrpcService/OutOfBandAuth',
          ($0.OutOfBandAuthReq value) => value.writeToBuffer(),
          $0.Empty.fromBuffer);
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
    $addMethod($grpc.ServiceMethod<$0.ClientChallenge, $0.ServerChallenge>(
        'ExchangeChallenges',
        exchangeChallenges_Pre,
        false,
        false,
        ($core.List<$core.int> value) => $0.ClientChallenge.fromBuffer(value),
        ($0.ServerChallenge value) => value.writeToBuffer()));
    $addMethod($grpc.ServiceMethod<$0.RingSignatureReq, $0.RingSignatureResp>(
        'ExchangeRingSignatures',
        exchangeRingSignatures_Pre,
        false,
        false,
        ($core.List<$core.int> value) => $0.RingSignatureReq.fromBuffer(value),
        ($0.RingSignatureResp value) => value.writeToBuffer()));
    $addMethod($grpc.ServiceMethod<$0.NicknameScheduleReqResp,
            $0.NicknameScheduleReqResp>(
        'ExchangeNicknameSchedule',
        exchangeNicknameSchedule_Pre,
        false,
        false,
        ($core.List<$core.int> value) =>
            $0.NicknameScheduleReqResp.fromBuffer(value),
        ($0.NicknameScheduleReqResp value) => value.writeToBuffer()));
    $addMethod($grpc.ServiceMethod<$0.NicknameScheduleAckReq,
            $0.NicknameScheduleAckResp>(
        'ExchangeNicknameScheduleAck',
        exchangeNicknameScheduleAck_Pre,
        false,
        false,
        ($core.List<$core.int> value) =>
            $0.NicknameScheduleAckReq.fromBuffer(value),
        ($0.NicknameScheduleAckResp value) => value.writeToBuffer()));
    $addMethod($grpc.ServiceMethod<$0.OutOfBandAuthReq, $0.Empty>(
        'OutOfBandAuth',
        outOfBandAuth_Pre,
        false,
        false,
        ($core.List<$core.int> value) => $0.OutOfBandAuthReq.fromBuffer(value),
        ($0.Empty value) => value.writeToBuffer()));
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

  $async.Future<$0.ServerChallenge> exchangeChallenges_Pre(
      $grpc.ServiceCall $call,
      $async.Future<$0.ClientChallenge> $request) async {
    return exchangeChallenges($call, await $request);
  }

  $async.Future<$0.ServerChallenge> exchangeChallenges(
      $grpc.ServiceCall call, $0.ClientChallenge request);

  $async.Future<$0.RingSignatureResp> exchangeRingSignatures_Pre(
      $grpc.ServiceCall $call,
      $async.Future<$0.RingSignatureReq> $request) async {
    return exchangeRingSignatures($call, await $request);
  }

  $async.Future<$0.RingSignatureResp> exchangeRingSignatures(
      $grpc.ServiceCall call, $0.RingSignatureReq request);

  $async.Future<$0.NicknameScheduleReqResp> exchangeNicknameSchedule_Pre(
      $grpc.ServiceCall $call,
      $async.Future<$0.NicknameScheduleReqResp> $request) async {
    return exchangeNicknameSchedule($call, await $request);
  }

  $async.Future<$0.NicknameScheduleReqResp> exchangeNicknameSchedule(
      $grpc.ServiceCall call, $0.NicknameScheduleReqResp request);

  $async.Future<$0.NicknameScheduleAckResp> exchangeNicknameScheduleAck_Pre(
      $grpc.ServiceCall $call,
      $async.Future<$0.NicknameScheduleAckReq> $request) async {
    return exchangeNicknameScheduleAck($call, await $request);
  }

  $async.Future<$0.NicknameScheduleAckResp> exchangeNicknameScheduleAck(
      $grpc.ServiceCall call, $0.NicknameScheduleAckReq request);

  $async.Future<$0.Empty> outOfBandAuth_Pre($grpc.ServiceCall $call,
      $async.Future<$0.OutOfBandAuthReq> $request) async {
    return outOfBandAuth($call, await $request);
  }

  $async.Future<$0.Empty> outOfBandAuth(
      $grpc.ServiceCall call, $0.OutOfBandAuthReq request);
}
