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

import 'package:flutter/services.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;

import 'package:livekit_client/src/internal/events.dart';
import 'package:livekit_client/src/track/local/audio.dart';
import 'package:livekit_client/src/track/local/local.dart';
import 'package:livekit_client/src/track/options.dart';
import 'package:livekit_client/src/types/other.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const webrtc = MethodChannel('FlutterWebRTC.Method');
  var streams = 0;

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(webrtc, (call) async {
      if (call.method != 'getUserMedia') return null;
      streams++;
      return {
        'streamId': 'stream-$streams',
        'audioTracks': [
          {'id': 'audio-$streams', 'label': 'microphone', 'kind': 'audio', 'enabled': true},
        ],
        'videoTracks': <Object>[],
      };
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(webrtc, null);
  });

  test('a track ended after restartTrack() is reported', () async {
    const options = AudioCaptureOptions();
    final stream = await LocalTrack.createStream(options);
    final track = LocalAudioTrack(TrackSource.microphone, stream, stream.getAudioTracks().first, options)
      ..transceiver = _FakeTransceiver();

    await track.restartTrack();
    expect(track.mediaStreamTrack.id, 'audio-2');

    final ended = track.events.waitFor<TrackEndedEvent>(duration: const Duration(seconds: 1));
    track.mediaStreamTrack.onEnded!();
    expect((await ended).track, track);
  });
}

class _FakeTransceiver implements rtc.RTCRtpTransceiver {
  @override
  final rtc.RTCRtpSender sender = _FakeSender();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeSender implements rtc.RTCRtpSender {
  @override
  Future<void> replaceTrack(rtc.MediaStreamTrack? track) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
