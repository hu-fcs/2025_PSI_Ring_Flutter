// This is a generated file - do not edit.
//
// Generated from psi.proto.

// @dart = 3.3

// ignore_for_file: annotate_overrides, camel_case_types, comment_references
// ignore_for_file: constant_identifier_names
// ignore_for_file: curly_braces_in_flow_control_structures
// ignore_for_file: deprecated_member_use_from_same_package, library_prefixes
// ignore_for_file: non_constant_identifier_names, prefer_relative_imports

import 'dart:core' as $core;

import 'package:protobuf/protobuf.dart' as $pb;

export 'package:protobuf/protobuf.dart' show GeneratedMessageGenericExtensions;

class PingReq extends $pb.GeneratedMessage {
  factory PingReq({
    $core.String? msg,
  }) {
    final result = create();
    if (msg != null) result.msg = msg;
    return result;
  }

  PingReq._();

  factory PingReq.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory PingReq.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'PingReq',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'psi'),
      createEmptyInstance: create)
    ..aOS(1, _omitFieldNames ? '' : 'msg')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  PingReq clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  PingReq copyWith(void Function(PingReq) updates) =>
      super.copyWith((message) => updates(message as PingReq)) as PingReq;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static PingReq create() => PingReq._();
  @$core.override
  PingReq createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static PingReq getDefault() =>
      _defaultInstance ??= $pb.GeneratedMessage.$_defaultFor<PingReq>(create);
  static PingReq? _defaultInstance;

  @$pb.TagNumber(1)
  $core.String get msg => $_getSZ(0);
  @$pb.TagNumber(1)
  set msg($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasMsg() => $_has(0);
  @$pb.TagNumber(1)
  void clearMsg() => $_clearField(1);
}

class PingResp extends $pb.GeneratedMessage {
  factory PingResp({
    $core.String? msg,
  }) {
    final result = create();
    if (msg != null) result.msg = msg;
    return result;
  }

  PingResp._();

  factory PingResp.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory PingResp.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'PingResp',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'psi'),
      createEmptyInstance: create)
    ..aOS(1, _omitFieldNames ? '' : 'msg')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  PingResp clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  PingResp copyWith(void Function(PingResp) updates) =>
      super.copyWith((message) => updates(message as PingResp)) as PingResp;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static PingResp create() => PingResp._();
  @$core.override
  PingResp createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static PingResp getDefault() =>
      _defaultInstance ??= $pb.GeneratedMessage.$_defaultFor<PingResp>(create);
  static PingResp? _defaultInstance;

  @$pb.TagNumber(1)
  $core.String get msg => $_getSZ(0);
  @$pb.TagNumber(1)
  set msg($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasMsg() => $_has(0);
  @$pb.TagNumber(1)
  void clearMsg() => $_clearField(1);
}

class KeyExchangeReq extends $pb.GeneratedMessage {
  factory KeyExchangeReq({
    $core.Iterable<$core.List<$core.int>>? keys,
  }) {
    final result = create();
    if (keys != null) result.keys.addAll(keys);
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
      package: const $pb.PackageName(_omitMessageNames ? '' : 'psi'),
      createEmptyInstance: create)
    ..p<$core.List<$core.int>>(
        1, _omitFieldNames ? '' : 'keys', $pb.PbFieldType.PY)
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
  $pb.PbList<$core.List<$core.int>> get keys => $_getList(0);
}

class KeyExchangeResp extends $pb.GeneratedMessage {
  factory KeyExchangeResp({
    $core.Iterable<$core.List<$core.int>>? keys,
  }) {
    final result = create();
    if (keys != null) result.keys.addAll(keys);
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
      package: const $pb.PackageName(_omitMessageNames ? '' : 'psi'),
      createEmptyInstance: create)
    ..p<$core.List<$core.int>>(
        1, _omitFieldNames ? '' : 'keys', $pb.PbFieldType.PY)
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
  $pb.PbList<$core.List<$core.int>> get keys => $_getList(0);
}

const $core.bool _omitFieldNames =
    $core.bool.fromEnvironment('protobuf.omit_field_names');
const $core.bool _omitMessageNames =
    $core.bool.fromEnvironment('protobuf.omit_message_names');
