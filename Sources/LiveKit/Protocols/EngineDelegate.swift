/*
 * Copyright 2023 LiveKit
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

import Foundation

@_implementationOnly import WebRTC

protocol EngineDelegate: AnyObject {
    func engine(_ engine: Engine, didMutate state: Engine.State, oldState: Engine.State)
    func engine(_ engine: Engine, didUpdate speakers: [Livekit_SpeakerInfo])
    func engine(_ engine: Engine, didAddTrack track: LKRTCMediaStreamTrack, rtpReceiver: LKRTCRtpReceiver, streams: [LKRTCMediaStream])
    func engine(_ engine: Engine, didRemove track: LKRTCMediaStreamTrack)
    func engine(_ engine: Engine, didReceive userPacket: Livekit_UserPacket)
}
