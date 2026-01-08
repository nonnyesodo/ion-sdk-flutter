import 'dart:async';
import 'dart:convert';

import 'package:events2/events2.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:grpc/grpc.dart';
import 'package:uuid/uuid.dart';

import '../_library/proto/rtc/rtc.pbgrpc.dart' as pb;

import 'grpc-web/_channel.dart'
    if (dart.library.html) 'grpc-web/_channel_html.dart';
import 'signal.dart';

class GRPCWebSignal extends Signal {
  GRPCWebSignal(this._uri,
      {List<int>? certificates, String? authority, String? password}) {
    var uri = Uri.parse(_uri);
    var channel = createChannel(uri.host, uri.port, uri.scheme == 'https');
    _client = pb.RTCClient(channel);
    _requestStream = StreamController<pb.Request>();
  }

  final String _uri;
  final JsonDecoder _jsonDecoder = JsonDecoder();
  final JsonEncoder _jsonEncoder = JsonEncoder();
  final Uuid _uuid = Uuid();
  final EventEmitter _emitter = EventEmitter();
  late pb.RTCClient _client;
  late StreamController<pb.Request> _requestStream;
  late ResponseStream<pb.Reply> _replyStream;

  void _onSignalReply(pb.Reply reply) {
    switch (reply.whichPayload()) {
      case pb.Reply_Payload.join:
        _emitter.emit('join-reply', reply.join.description);
        break;
      case pb.Reply_Payload.description:
        var desc = RTCSessionDescription(
            reply.description.sdp, reply.description.type);
        if (reply.description.type == 'offer') {
          onnegotiate?.call(desc);
        } else {
          _emitter.emit('description', reply, reply.description);
        }
        break;
      case pb.Reply_Payload.trickle:
        var map = {
          'target': reply.trickle.target.value,
          'candidate': _jsonDecoder.convert(reply.trickle.init)
        };
        ontrickle?.call(Trickle.fromMap(map));
        break;
      // case pb.Reply_Payload.iceConnectionState:
      case pb.Reply_Payload.error:
      case pb.Reply_Payload.notSet:
      case pb.Reply_Payload.subscription:
      case pb.Reply_Payload.trackEvent:
        break;
    }
  }

  @override
  Future<void> connect() async {
    _replyStream = _client.signal(_requestStream.stream);
    _replyStream.listen(_onSignalReply,
        onDone: () => onclose?.call(0, 'closed'),
        onError: (e) => onclose?.call(500, '$e'));
    onready?.call();
  }

  @override
  void close() {
    _requestStream.close();
    _replyStream.cancel();
  }

  // @override
  // Future<RTCSessionDescription> join(
  //     String sid, String uid, RTCSessionDescription offer) {
  //   Completer completer = Completer<RTCSessionDescription>();
  //   var request = pb.Request()
  //     ..join = (pb.JoinRequest()
  //       ..description = offer.toMap()
  //       ..sid = sid
  //       ..uid = uid);
  //   _requestStream.add(request);

  //   Function(RTCSessionDescription) handler;
  //   handler = (desc) {
  //     completer.complete(desc);
  //   };
  //   _emitter.once('join-reply', handler);
  //   return completer.future as Future<RTCSessionDescription>;
  // }
  @override
  Future<RTCSessionDescription> join(
      String sid, String uid, RTCSessionDescription offer) {
    var completer = Completer<RTCSessionDescription>();

    // Create the Protobuf SessionDescription object
    var pbDescription = pb.SessionDescription()
      ..sdp = offer.sdp!
      ..type = offer.type!;

    var request = pb.Request()
      ..join = (pb.JoinRequest()
        ..description = pbDescription // Use the Proto object, not a Map
        ..sid = sid
        ..uid = uid);

    _requestStream.add(request);

    // Note: The reply is likely coming back as a Proto SessionDescription too
    _emitter.once('join-reply', (dynamic desc) {
      if (desc is pb.SessionDescription) {
        completer.complete(RTCSessionDescription(desc.sdp, desc.type));
      } else {
        // Fallback for different response types
        completer.complete(desc as RTCSessionDescription);
      }
    });

    return completer.future;
  }

  // @override
  // Future<RTCSessionDescription> offer(RTCSessionDescription offer) {
  // Completer completer = Completer<RTCSessionDescription>();
  // var id = _uuid.v4();
  //   var request = pb.Request()..description = offer.toMap();
  // _requestStream.add(request);
  // Function(String, dynamic) handler;
  // handler = (respid, desc) {
  //   if (respid == id) {
  //     completer.complete(desc);
  //   }
  // };
  // _emitter.once('description', handler);
  // return completer.future as Future<RTCSessionDescription>;
  // }
  @override
  Future<RTCSessionDescription> offer(RTCSessionDescription offer) {
    Completer completer = Completer<RTCSessionDescription>();
    var id = _uuid.v4();
    var pbDescription = pb.SessionDescription()
      ..sdp = offer.sdp!
      ..type = offer.type!;

    var request = pb.Request()..description = pbDescription;
    _requestStream.add(request);
    Function(String, dynamic) handler;
    handler = (respid, desc) {
      if (respid == id) {
        completer.complete(desc);
      }
    };
    _emitter.once('description', handler);
    return completer.future as Future<RTCSessionDescription>;
  }

  @override
  void answer(RTCSessionDescription answer) {
    var pbDescription = pb.SessionDescription()
      ..sdp = answer.sdp!
      ..type = answer.type!;

    var reply = pb.Request()..description = pbDescription;
    _requestStream.add(reply);
  }

  // @override
  // void answer(RTCSessionDescription answer) {
  //   var reply = pb.Request()..description = answer.toMap();
  //   _requestStream.add(reply);
  // }

  @override
  void trickle(Trickle trickle) {
    var reply = pb.Request()
      ..trickle = (pb.Trickle()
        ..target = pb.Target.valueOf(trickle.target)!
        ..init = _jsonEncoder.convert(trickle.candidate.toMap()));
    _requestStream.add(reply);
  }
}
