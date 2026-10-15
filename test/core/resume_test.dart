// Copyright 2026 LiveKit, Inc.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

@Timeout(Duration(seconds: 10))
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;

import 'package:livekit_client/livekit_client.dart';
import 'package:livekit_client/src/proto/livekit_models.pb.dart' as lk_models;
import 'package:livekit_client/src/proto/livekit_rtc.pb.dart' as lk_rtc;
import 'package:livekit_client/src/support/websocket.dart';
import 'package:livekit_client/src/types/internal.dart';
import '../mock/e2e_container.dart';
import '../mock/peerconnection_mock.dart';
import '../mock/websocket_mock.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late E2EContainer container;
  late MockWebSocketConnector ws;

  setUp(() async {
    resetMockDataChannels();
    container = E2EContainer();
    ws = container.wsConnector;
    await container.connectRoom();
  });

  tearDown(() async {
    await container.dispose();
  });

  Future<void> until(bool Function() condition) async {
    for (var i = 0; i < 200 && !condition(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(condition(), isTrue);
  }

  /// Negotiates the publisher and answers its offer, as a first publication does.
  Future<void> publish() async {
    final publisher = container.engine.publisher!;
    await container.engine.negotiate();
    await until(() => publisher.pc.signalingState == rtc.RTCSignalingState.RTCSignalingStateHaveLocalOffer);
    ws.onData(
      lk_rtc.SignalResponse(
        answer: lk_rtc.SessionDescription(type: 'answer', sdp: 'remote_answer'),
      ).writeToBuffer(),
    );
    await until(() => publisher.pc.connectionState == rtc.RTCPeerConnectionState.RTCPeerConnectionStateConnected);
  }

  /// Offers sent by the publisher from now on.
  List<rtc.RTCSessionDescription> publisherOffers() {
    final offers = <rtc.RTCSessionDescription>[];
    final publisher = container.engine.publisher!;
    final send = publisher.onOffer;
    publisher.onOffer = (offer) {
      offers.add(offer);
      send?.call(offer);
    };
    return offers;
  }

  Future<void> resume(Future<void> Function() lose) async {
    final previousHandlers = ws.handlers;
    await lose();
    await until(() => !identical(ws.handlers, previousHandlers));
    ws.onData(lk_rtc.SignalResponse(reconnect: lk_rtc.ReconnectResponse()).writeToBuffer());
    await container.room.events.waitFor<RoomReconnectedEvent>(duration: const Duration(seconds: 5));
  }

  group('publisher ICE on resume', () {
    test('is left alone when only the signal connection was lost', () async {
      await publish();
      final offers = publisherOffers();

      await resume(() async => ws.onDispose());

      expect(offers, isEmpty);
    });

    test('is restarted when asked to switch candidates', () async {
      await publish();
      final offers = publisherOffers();

      await resume(
        () => container.engine.handleReconnect(
          ClientDisconnectReason.reconnect,
          reconnectReason: lk_models.ReconnectReason.RR_SWITCH_CANDIDATE,
        ),
      );

      expect(offers, hasLength(1));
      expect(container.engine.publisher!.restartingIce, isTrue);
    });
  });

  group('reconnect reason', () {
    /// The reason sent by the resume that follows a refused one.
    Future<String?> retriedReason(Future<void> Function() lose) async {
      ws.connectError = WebSocketException('refused');
      await lose();
      await container.room.events.waitFor<RoomAttemptReconnectEvent>(
        duration: const Duration(seconds: 5),
        filter: (event) => event.attempt == 2,
      );
      final previousHandlers = ws.handlers;
      ws.connectError = null;
      await until(() => !identical(ws.handlers, previousHandlers));
      return ws.uri!.queryParameters['reconnect_reason'];
    }

    test('is kept by a retry', () async {
      final reason = await retriedReason(() async => ws.onDispose());
      expect(reason, '${lk_models.ReconnectReason.RR_SIGNAL_DISCONNECTED.value}');
    });
  });
}
