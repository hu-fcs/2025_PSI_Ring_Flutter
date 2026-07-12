// This is a generated file - do not edit.
//
// Generated from grpc.proto.

// @dart = 3.3

// ignore_for_file: annotate_overrides, camel_case_types, comment_references
// ignore_for_file: constant_identifier_names
// ignore_for_file: curly_braces_in_flow_control_structures
// ignore_for_file: deprecated_member_use_from_same_package, library_prefixes
// ignore_for_file: non_constant_identifier_names, prefer_relative_imports

import 'dart:core' as $core;

import 'package:fixnum/fixnum.dart' as $fixnum;
import 'package:protobuf/protobuf.dart' as $pb;

export 'package:protobuf/protobuf.dart' show GeneratedMessageGenericExtensions;

/// PSI の3段階（鍵交換 → PSI確定 → 匿名認証）のための gRPC 定義。
/// PSI Phase 1: PSI 鍵交換
class KeyExchangeReq extends $pb.GeneratedMessage {
  factory KeyExchangeReq({
    $core.Iterable<$core.List<$core.int>>? encKeys,
  }) {
    final result = create();
    if (encKeys != null) result.encKeys.addAll(encKeys);
    return result;
  }

  KeyExchangeReq._();

  factory KeyExchangeReq.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory KeyExchangeReq.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'KeyExchangeReq',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'grpc'),
      createEmptyInstance: create)
    ..p<$core.List<$core.int>>(
        1, _omitFieldNames ? '' : 'encKeys', $pb.PbFieldType.PY)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  KeyExchangeReq clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  KeyExchangeReq copyWith(void Function(KeyExchangeReq) updates) =>
      super.copyWith((message) => updates(message as KeyExchangeReq))
          as KeyExchangeReq;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static KeyExchangeReq create() => KeyExchangeReq._();
  @$core.override
  KeyExchangeReq createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static KeyExchangeReq getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<KeyExchangeReq>(create);
  static KeyExchangeReq? _defaultInstance;

  @$pb.TagNumber(1)
  $pb.PbList<$core.List<$core.int>> get encKeys => $_getList(0);
}

class KeyExchangeResp extends $pb.GeneratedMessage {
  factory KeyExchangeResp({
    $core.Iterable<$core.List<$core.int>>? serverEncKeys,
    $core.Iterable<$core.List<$core.int>>? clientReencKeys,
  }) {
    final result = create();
    if (serverEncKeys != null) result.serverEncKeys.addAll(serverEncKeys);
    if (clientReencKeys != null) result.clientReencKeys.addAll(clientReencKeys);
    return result;
  }

  KeyExchangeResp._();

  factory KeyExchangeResp.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory KeyExchangeResp.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'KeyExchangeResp',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'grpc'),
      createEmptyInstance: create)
    ..p<$core.List<$core.int>>(
        1, _omitFieldNames ? '' : 'serverEncKeys', $pb.PbFieldType.PY)
    ..p<$core.List<$core.int>>(
        2, _omitFieldNames ? '' : 'clientReencKeys', $pb.PbFieldType.PY)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  KeyExchangeResp clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  KeyExchangeResp copyWith(void Function(KeyExchangeResp) updates) =>
      super.copyWith((message) => updates(message as KeyExchangeResp))
          as KeyExchangeResp;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static KeyExchangeResp create() => KeyExchangeResp._();
  @$core.override
  KeyExchangeResp createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static KeyExchangeResp getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<KeyExchangeResp>(create);
  static KeyExchangeResp? _defaultInstance;

  @$pb.TagNumber(1)
  $pb.PbList<$core.List<$core.int>> get serverEncKeys => $_getList(0);

  @$pb.TagNumber(2)
  $pb.PbList<$core.List<$core.int>> get clientReencKeys => $_getList(1);
}

/// PSI Phase 2: PSI 確定
class ClientFinalReq extends $pb.GeneratedMessage {
  factory ClientFinalReq({
    $core.Iterable<$core.List<$core.int>>? clientReencServerKeys,
  }) {
    final result = create();
    if (clientReencServerKeys != null)
      result.clientReencServerKeys.addAll(clientReencServerKeys);
    return result;
  }

  ClientFinalReq._();

  factory ClientFinalReq.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory ClientFinalReq.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'ClientFinalReq',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'grpc'),
      createEmptyInstance: create)
    ..p<$core.List<$core.int>>(
        1, _omitFieldNames ? '' : 'clientReencServerKeys', $pb.PbFieldType.PY)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ClientFinalReq clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ClientFinalReq copyWith(void Function(ClientFinalReq) updates) =>
      super.copyWith((message) => updates(message as ClientFinalReq))
          as ClientFinalReq;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static ClientFinalReq create() => ClientFinalReq._();
  @$core.override
  ClientFinalReq createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static ClientFinalReq getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<ClientFinalReq>(create);
  static ClientFinalReq? _defaultInstance;

  @$pb.TagNumber(1)
  $pb.PbList<$core.List<$core.int>> get clientReencServerKeys => $_getList(0);
}

class PsiDone extends $pb.GeneratedMessage {
  factory PsiDone() => create();

  PsiDone._();

  factory PsiDone.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory PsiDone.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'PsiDone',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'grpc'),
      createEmptyInstance: create)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  PsiDone clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  PsiDone copyWith(void Function(PsiDone) updates) =>
      super.copyWith((message) => updates(message as PsiDone)) as PsiDone;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static PsiDone create() => PsiDone._();
  @$core.override
  PsiDone createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static PsiDone getDefault() =>
      _defaultInstance ??= $pb.GeneratedMessage.$_defaultFor<PsiDone>(create);
  static PsiDone? _defaultInstance;
}

/// PSI Phase 3A: チャレンジ交換
/// クライアント → サーバ
class ClientChallenge extends $pb.GeneratedMessage {
  factory ClientChallenge({
    $core.List<$core.int>? challengeC,
  }) {
    final result = create();
    if (challengeC != null) result.challengeC = challengeC;
    return result;
  }

  ClientChallenge._();

  factory ClientChallenge.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory ClientChallenge.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'ClientChallenge',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'grpc'),
      createEmptyInstance: create)
    ..a<$core.List<$core.int>>(
        1, _omitFieldNames ? '' : 'challengeC', $pb.PbFieldType.OY)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ClientChallenge clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ClientChallenge copyWith(void Function(ClientChallenge) updates) =>
      super.copyWith((message) => updates(message as ClientChallenge))
          as ClientChallenge;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static ClientChallenge create() => ClientChallenge._();
  @$core.override
  ClientChallenge createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static ClientChallenge getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<ClientChallenge>(create);
  static ClientChallenge? _defaultInstance;

  @$pb.TagNumber(1)
  $core.List<$core.int> get challengeC => $_getN(0);
  @$pb.TagNumber(1)
  set challengeC($core.List<$core.int> value) => $_setBytes(0, value);
  @$pb.TagNumber(1)
  $core.bool hasChallengeC() => $_has(0);
  @$pb.TagNumber(1)
  void clearChallengeC() => $_clearField(1);
}

/// サーバ → クライアント
class ServerChallenge extends $pb.GeneratedMessage {
  factory ServerChallenge({
    $core.List<$core.int>? challengeS,
  }) {
    final result = create();
    if (challengeS != null) result.challengeS = challengeS;
    return result;
  }

  ServerChallenge._();

  factory ServerChallenge.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory ServerChallenge.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'ServerChallenge',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'grpc'),
      createEmptyInstance: create)
    ..a<$core.List<$core.int>>(
        1, _omitFieldNames ? '' : 'challengeS', $pb.PbFieldType.OY)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ServerChallenge clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ServerChallenge copyWith(void Function(ServerChallenge) updates) =>
      super.copyWith((message) => updates(message as ServerChallenge))
          as ServerChallenge;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static ServerChallenge create() => ServerChallenge._();
  @$core.override
  ServerChallenge createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static ServerChallenge getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<ServerChallenge>(create);
  static ServerChallenge? _defaultInstance;

  @$pb.TagNumber(1)
  $core.List<$core.int> get challengeS => $_getN(0);
  @$pb.TagNumber(1)
  set challengeS($core.List<$core.int> value) => $_setBytes(0, value);
  @$pb.TagNumber(1)
  $core.bool hasChallengeS() => $_has(0);
  @$pb.TagNumber(1)
  void clearChallengeS() => $_clearField(1);
}

/// PSI Phase 3B: リング署名交換
/// クライアント → サーバ
class RingSignatureReq extends $pb.GeneratedMessage {
  factory RingSignatureReq({
    $core.List<$core.int>? signatureForServer,
  }) {
    final result = create();
    if (signatureForServer != null)
      result.signatureForServer = signatureForServer;
    return result;
  }

  RingSignatureReq._();

  factory RingSignatureReq.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory RingSignatureReq.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'RingSignatureReq',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'grpc'),
      createEmptyInstance: create)
    ..a<$core.List<$core.int>>(
        1, _omitFieldNames ? '' : 'signatureForServer', $pb.PbFieldType.OY)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  RingSignatureReq clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  RingSignatureReq copyWith(void Function(RingSignatureReq) updates) =>
      super.copyWith((message) => updates(message as RingSignatureReq))
          as RingSignatureReq;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static RingSignatureReq create() => RingSignatureReq._();
  @$core.override
  RingSignatureReq createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static RingSignatureReq getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<RingSignatureReq>(create);
  static RingSignatureReq? _defaultInstance;

  @$pb.TagNumber(1)
  $core.List<$core.int> get signatureForServer => $_getN(0);
  @$pb.TagNumber(1)
  set signatureForServer($core.List<$core.int> value) => $_setBytes(0, value);
  @$pb.TagNumber(1)
  $core.bool hasSignatureForServer() => $_has(0);
  @$pb.TagNumber(1)
  void clearSignatureForServer() => $_clearField(1);
}

/// サーバ → クライアント
class RingSignatureResp extends $pb.GeneratedMessage {
  factory RingSignatureResp({
    $core.List<$core.int>? signatureForClient,
  }) {
    final result = create();
    if (signatureForClient != null)
      result.signatureForClient = signatureForClient;
    return result;
  }

  RingSignatureResp._();

  factory RingSignatureResp.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory RingSignatureResp.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'RingSignatureResp',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'grpc'),
      createEmptyInstance: create)
    ..a<$core.List<$core.int>>(
        1, _omitFieldNames ? '' : 'signatureForClient', $pb.PbFieldType.OY)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  RingSignatureResp clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  RingSignatureResp copyWith(void Function(RingSignatureResp) updates) =>
      super.copyWith((message) => updates(message as RingSignatureResp))
          as RingSignatureResp;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static RingSignatureResp create() => RingSignatureResp._();
  @$core.override
  RingSignatureResp createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static RingSignatureResp getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<RingSignatureResp>(create);
  static RingSignatureResp? _defaultInstance;

  @$pb.TagNumber(1)
  $core.List<$core.int> get signatureForClient => $_getN(0);
  @$pb.TagNumber(1)
  set signatureForClient($core.List<$core.int> value) => $_setBytes(0, value);
  @$pb.TagNumber(1)
  $core.bool hasSignatureForClient() => $_has(0);
  @$pb.TagNumber(1)
  void clearSignatureForClient() => $_clearField(1);
}

/// 将来ニックネームの共有 Phase 1
/// request (ack_length なし）
/// response (ack_length あり）
class NicknameScheduleReqResp extends $pb.GeneratedMessage {
  factory NicknameScheduleReqResp({
    $core.String? ownerName,
    $fixnum.Int64? periodDays,
    $fixnum.Int64? slotMs,
    $fixnum.Int64? firstSlotMs,
    $core.Iterable<$core.List<$core.int>>? nicknameList,
    $fixnum.Int64? ackLength,
  }) {
    final result = create();
    if (ownerName != null) result.ownerName = ownerName;
    if (periodDays != null) result.periodDays = periodDays;
    if (slotMs != null) result.slotMs = slotMs;
    if (firstSlotMs != null) result.firstSlotMs = firstSlotMs;
    if (nicknameList != null) result.nicknameList.addAll(nicknameList);
    if (ackLength != null) result.ackLength = ackLength;
    return result;
  }

  NicknameScheduleReqResp._();

  factory NicknameScheduleReqResp.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory NicknameScheduleReqResp.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'NicknameScheduleReqResp',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'grpc'),
      createEmptyInstance: create)
    ..aOS(1, _omitFieldNames ? '' : 'ownerName')
    ..aInt64(2, _omitFieldNames ? '' : 'periodDays')
    ..aInt64(3, _omitFieldNames ? '' : 'slotMs')
    ..aInt64(4, _omitFieldNames ? '' : 'firstSlotMs')
    ..p<$core.List<$core.int>>(
        5, _omitFieldNames ? '' : 'nicknameList', $pb.PbFieldType.PY)
    ..aInt64(6, _omitFieldNames ? '' : 'ackLength')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  NicknameScheduleReqResp clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  NicknameScheduleReqResp copyWith(
          void Function(NicknameScheduleReqResp) updates) =>
      super.copyWith((message) => updates(message as NicknameScheduleReqResp))
          as NicknameScheduleReqResp;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static NicknameScheduleReqResp create() => NicknameScheduleReqResp._();
  @$core.override
  NicknameScheduleReqResp createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static NicknameScheduleReqResp getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<NicknameScheduleReqResp>(create);
  static NicknameScheduleReqResp? _defaultInstance;

  @$pb.TagNumber(1)
  $core.String get ownerName => $_getSZ(0);
  @$pb.TagNumber(1)
  set ownerName($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasOwnerName() => $_has(0);
  @$pb.TagNumber(1)
  void clearOwnerName() => $_clearField(1);

  @$pb.TagNumber(2)
  $fixnum.Int64 get periodDays => $_getI64(1);
  @$pb.TagNumber(2)
  set periodDays($fixnum.Int64 value) => $_setInt64(1, value);
  @$pb.TagNumber(2)
  $core.bool hasPeriodDays() => $_has(1);
  @$pb.TagNumber(2)
  void clearPeriodDays() => $_clearField(2);

  @$pb.TagNumber(3)
  $fixnum.Int64 get slotMs => $_getI64(2);
  @$pb.TagNumber(3)
  set slotMs($fixnum.Int64 value) => $_setInt64(2, value);
  @$pb.TagNumber(3)
  $core.bool hasSlotMs() => $_has(2);
  @$pb.TagNumber(3)
  void clearSlotMs() => $_clearField(3);

  @$pb.TagNumber(4)
  $fixnum.Int64 get firstSlotMs => $_getI64(3);
  @$pb.TagNumber(4)
  set firstSlotMs($fixnum.Int64 value) => $_setInt64(3, value);
  @$pb.TagNumber(4)
  $core.bool hasFirstSlotMs() => $_has(3);
  @$pb.TagNumber(4)
  void clearFirstSlotMs() => $_clearField(4);

  @$pb.TagNumber(5)
  $pb.PbList<$core.List<$core.int>> get nicknameList => $_getList(4);

  @$pb.TagNumber(6)
  $fixnum.Int64 get ackLength => $_getI64(5);
  @$pb.TagNumber(6)
  set ackLength($fixnum.Int64 value) => $_setInt64(5, value);
  @$pb.TagNumber(6)
  $core.bool hasAckLength() => $_has(5);
  @$pb.TagNumber(6)
  void clearAckLength() => $_clearField(6);
}

/// 将来ニックネームの共有 Phase 2: 受信確認
class NicknameScheduleAckReq extends $pb.GeneratedMessage {
  factory NicknameScheduleAckReq({
    $core.String? ownerName,
    $fixnum.Int64? ackLength,
  }) {
    final result = create();
    if (ownerName != null) result.ownerName = ownerName;
    if (ackLength != null) result.ackLength = ackLength;
    return result;
  }

  NicknameScheduleAckReq._();

  factory NicknameScheduleAckReq.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory NicknameScheduleAckReq.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'NicknameScheduleAckReq',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'grpc'),
      createEmptyInstance: create)
    ..aOS(1, _omitFieldNames ? '' : 'ownerName')
    ..aInt64(6, _omitFieldNames ? '' : 'ackLength')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  NicknameScheduleAckReq clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  NicknameScheduleAckReq copyWith(
          void Function(NicknameScheduleAckReq) updates) =>
      super.copyWith((message) => updates(message as NicknameScheduleAckReq))
          as NicknameScheduleAckReq;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static NicknameScheduleAckReq create() => NicknameScheduleAckReq._();
  @$core.override
  NicknameScheduleAckReq createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static NicknameScheduleAckReq getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<NicknameScheduleAckReq>(create);
  static NicknameScheduleAckReq? _defaultInstance;

  @$pb.TagNumber(1)
  $core.String get ownerName => $_getSZ(0);
  @$pb.TagNumber(1)
  set ownerName($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasOwnerName() => $_has(0);
  @$pb.TagNumber(1)
  void clearOwnerName() => $_clearField(1);

  @$pb.TagNumber(6)
  $fixnum.Int64 get ackLength => $_getI64(1);
  @$pb.TagNumber(6)
  set ackLength($fixnum.Int64 value) => $_setInt64(1, value);
  @$pb.TagNumber(6)
  $core.bool hasAckLength() => $_has(1);
  @$pb.TagNumber(6)
  void clearAckLength() => $_clearField(6);
}

class NicknameScheduleAckResp extends $pb.GeneratedMessage {
  factory NicknameScheduleAckResp() => create();

  NicknameScheduleAckResp._();

  factory NicknameScheduleAckResp.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory NicknameScheduleAckResp.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'NicknameScheduleAckResp',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'grpc'),
      createEmptyInstance: create)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  NicknameScheduleAckResp clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  NicknameScheduleAckResp copyWith(
          void Function(NicknameScheduleAckResp) updates) =>
      super.copyWith((message) => updates(message as NicknameScheduleAckResp))
          as NicknameScheduleAckResp;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static NicknameScheduleAckResp create() => NicknameScheduleAckResp._();
  @$core.override
  NicknameScheduleAckResp createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static NicknameScheduleAckResp getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<NicknameScheduleAckResp>(create);
  static NicknameScheduleAckResp? _defaultInstance;
}

/// ----- OOB (Out-of-band) 認証
/// サーバがナンス（確認コード）を生成し，QRコードやBLEでクライアントに送信
/// クライアントはgRPC接続の最初にナンスを送信することを
/// サーバはナンスの一致していれば，クライアント認証に成功．その後PSIやNicknameScheduleの要求を受け付ける．
/// 不一致なら切断し，サーバ側のユーザに通知
/// QRコードやBLEがgRPC外のOOB通信．QRコードでのナンスは10進表現で3桁の整数．100から999までの900通り
class OutOfBandAuthReq extends $pb.GeneratedMessage {
  factory OutOfBandAuthReq({
    $fixnum.Int64? oobNance,
  }) {
    final result = create();
    if (oobNance != null) result.oobNance = oobNance;
    return result;
  }

  OutOfBandAuthReq._();

  factory OutOfBandAuthReq.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory OutOfBandAuthReq.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'OutOfBandAuthReq',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'grpc'),
      createEmptyInstance: create)
    ..aInt64(1, _omitFieldNames ? '' : 'oobNance')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  OutOfBandAuthReq clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  OutOfBandAuthReq copyWith(void Function(OutOfBandAuthReq) updates) =>
      super.copyWith((message) => updates(message as OutOfBandAuthReq))
          as OutOfBandAuthReq;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static OutOfBandAuthReq create() => OutOfBandAuthReq._();
  @$core.override
  OutOfBandAuthReq createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static OutOfBandAuthReq getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<OutOfBandAuthReq>(create);
  static OutOfBandAuthReq? _defaultInstance;

  @$pb.TagNumber(1)
  $fixnum.Int64 get oobNance => $_getI64(0);
  @$pb.TagNumber(1)
  set oobNance($fixnum.Int64 value) => $_setInt64(0, value);
  @$pb.TagNumber(1)
  $core.bool hasOobNance() => $_has(0);
  @$pb.TagNumber(1)
  void clearOobNance() => $_clearField(1);
}

class Empty extends $pb.GeneratedMessage {
  factory Empty() => create();

  Empty._();

  factory Empty.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory Empty.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'Empty',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'grpc'),
      createEmptyInstance: create)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  Empty clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  Empty copyWith(void Function(Empty) updates) =>
      super.copyWith((message) => updates(message as Empty)) as Empty;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static Empty create() => Empty._();
  @$core.override
  Empty createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static Empty getDefault() =>
      _defaultInstance ??= $pb.GeneratedMessage.$_defaultFor<Empty>(create);
  static Empty? _defaultInstance;
}

const $core.bool _omitFieldNames =
    $core.bool.fromEnvironment('protobuf.omit_field_names');
const $core.bool _omitMessageNames =
    $core.bool.fromEnvironment('protobuf.omit_message_names');
