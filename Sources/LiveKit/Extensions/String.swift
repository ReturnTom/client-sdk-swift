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

class Identity {
    let identity: String
    let publish: String?

    init(identity: String,
         publish: String?)
    {
        self.identity = identity
        self.publish = publish
    }
}

extension Livekit_ParticipantInfo {
    // parses identity string for the &publish= param of identity
    func parseIdentity() -> Identity {
        let segments = identity.split(separator: "#", maxSplits: 1)
        var publishSegment: String?
        if segments.count >= 2 {
            publishSegment = String(segments[1])
        }

        return Identity(
            identity: String(segments[0]),
            publish: publishSegment
        )
    }
}
