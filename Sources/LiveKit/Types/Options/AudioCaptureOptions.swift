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

@objc
public class AudioCaptureOptions: NSObject, CaptureOptions {
    @objc
    public let echoCancellation: Bool

    @objc
    public let noiseSuppression: Bool

    @objc
    public let autoGainControl: Bool

    @objc
    public let typingNoiseDetection: Bool

    @objc
    public let highpassFilter: Bool

    @objc
    public let experimentalNoiseSuppression: Bool = false

    @objc
    public let experimentalAutoGainControl: Bool = false

    public init(echoCancellation: Bool = true,
                noiseSuppression: Bool = true,
                autoGainControl: Bool = true,
                typingNoiseDetection: Bool = true,
                highpassFilter: Bool = true)
    {
        self.echoCancellation = echoCancellation
        self.noiseSuppression = noiseSuppression
        self.autoGainControl = autoGainControl
        self.typingNoiseDetection = typingNoiseDetection
        self.highpassFilter = highpassFilter
    }

    // MARK: - Equatable

    override public func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? Self else { return false }
        return echoCancellation == other.echoCancellation &&
            noiseSuppression == other.noiseSuppression &&
            autoGainControl == other.autoGainControl &&
            typingNoiseDetection == other.typingNoiseDetection &&
            highpassFilter == other.highpassFilter &&
            experimentalNoiseSuppression == other.experimentalNoiseSuppression &&
            experimentalAutoGainControl == other.experimentalAutoGainControl
    }

    override public var hash: Int {
        var hasher = Hasher()
        hasher.combine(echoCancellation)
        hasher.combine(noiseSuppression)
        hasher.combine(autoGainControl)
        hasher.combine(typingNoiseDetection)
        hasher.combine(highpassFilter)
        hasher.combine(experimentalNoiseSuppression)
        hasher.combine(experimentalAutoGainControl)
        return hasher.finalize()
    }
}
