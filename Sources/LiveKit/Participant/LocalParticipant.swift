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

#if canImport(ReplayKit)
    import ReplayKit
#endif

@_implementationOnly import WebRTC

@objc
public class LocalParticipant: Participant {
    @objc
    public var localAudioTracks: [LocalTrackPublication] { audioTracks.compactMap { $0 as? LocalTrackPublication } }

    @objc
    public var localVideoTracks: [LocalTrackPublication] { videoTracks.compactMap { $0 as? LocalTrackPublication } }

    private var allParticipantsAllowed: Bool = true
    private var trackPermissions: [ParticipantTrackPermission] = []

    init(room: Room) {
        super.init(sid: "", room: room)
    }

    func getTrackPublication(sid: Sid) -> LocalTrackPublication? {
        _state.tracks[sid] as? LocalTrackPublication
    }

    @objc
    @discardableResult
    func publish(track: LocalTrack, publishOptions: PublishOptions? = nil) async throws -> LocalTrackPublication {
        log("[publish] \(track) options: \(String(describing: publishOptions ?? nil))...", .info)

        guard let publisher = room.engine.publisher else {
            throw EngineError.state(message: "Publisher is nil")
        }

        guard _state.tracks.values.first(where: { $0.track === track }) == nil else {
            throw TrackError.publish(message: "This track has already been published.")
        }

        guard track is LocalVideoTrack || track is LocalAudioTrack else {
            throw TrackError.publish(message: "Unknown LocalTrack type")
        }

        // Try to start the Track
        try await track.start()
        // Starting the Track could be time consuming especially for camera etc.
        // Check cancellation after track starts.
        try Task.checkCancellation()

        do {
            var dimensions: Dimensions? // Only for Video

            if let track = track as? LocalVideoTrack {
                // Wait for Dimensions...
                log("[Publish] Waiting for dimensions to resolve...")
                dimensions = try await track.capturer.dimensionsCompleter.wait()
            }

            let populatorFunc: SignalClient.AddTrackRequestPopulator<LKRTCRtpTransceiverInit> = { populator in

                let transInit = DispatchQueue.liveKitWebRTC.sync { LKRTCRtpTransceiverInit() }
                transInit.direction = .sendOnly

                if let track = track as? LocalVideoTrack {
                    guard let dimensions else {
                        throw TrackError.publish(message: "VideoCapturer dimensions are unknown")
                    }

                    self.log("[publish] computing encode settings with dimensions: \(dimensions)...")

                    let publishOptions = (publishOptions as? VideoPublishOptions) ?? self.room._state.options.defaultVideoPublishOptions

                    let encodings = Utils.computeEncodings(dimensions: dimensions,
                                                           publishOptions: publishOptions,
                                                           isScreenShare: track.source == .screenShareVideo)

                    self.log("[publish] using encodings: \(encodings)")
                    transInit.sendEncodings = encodings

                    let videoLayers = dimensions.videoLayers(for: encodings)

                    self.log("[publish] using layers: \(videoLayers.map { String(describing: $0) }.joined(separator: ", "))")

                    populator.width = UInt32(dimensions.width)
                    populator.height = UInt32(dimensions.height)
                    populator.layers = videoLayers

                    self.log("[publish] requesting add track to server with \(populator)...")

                } else if track is LocalAudioTrack {
                    // additional params for Audio
                    let publishOptions = (publishOptions as? AudioPublishOptions) ?? self.room._state.options.defaultAudioPublishOptions

                    populator.disableDtx = !publishOptions.dtx

                    let encoding = publishOptions.encoding ?? AudioEncoding.presetSpeech

                    self.log("[publish] maxBitrate: \(encoding.maxBitrate)")

                    transInit.sendEncodings = [
                        Engine.createRtpEncodingParameters(encoding: encoding),
                    ]
                }

                return transInit
            }

            // Request a new track to the server
            let addTrackResult = try await room.engine.signalClient.sendAddTrack(cid: track.mediaTrack.trackId,
                                                                                 name: track.name,
                                                                                 type: track.kind.toPBType(),
                                                                                 source: track.source.toPBType(),
                                                                                 encryption: room.e2eeManager?.e2eeOptions.encryptionType.toPBType() ?? .none,
                                                                                 populatorFunc)

            log("[Publish] server responded trackInfo: \(addTrackResult.trackInfo)")

            // Add transceiver to pc
            let transceiver = try publisher.addTransceiver(with: track.mediaTrack, transceiverInit: addTrackResult.result)
            log("[Publish] Added transceiver: \(addTrackResult.trackInfo)...")

            do {
                try await track.onPublish()

                // Store publishOptions used for this track...
                track._publishOptions = publishOptions

                // Attach sender to track...
                track.set(transport: publisher, rtpSender: transceiver.sender)

                if track is LocalVideoTrack {
                    let publishOptions = (publishOptions as? VideoPublishOptions) ?? room._state.options.defaultVideoPublishOptions
                    // if screen share or simulcast is enabled,
                    // degrade resolution by using server's layer switching logic instead of WebRTC's logic
                    if track.source == .screenShareVideo || publishOptions.simulcast {
                        log("[publish] set degradationPreference to .maintainResolution")
                        let params = transceiver.sender.parameters
                        params.degradationPreference = NSNumber(value: RTCDegradationPreference.maintainResolution.rawValue)
                        // changing params directly doesn't work so we need to update params
                        // and set it back to sender.parameters
                        transceiver.sender.parameters = params
                    }
                }

                try await room.engine.publisherShouldNegotiate()
                try Task.checkCancellation()

            } catch {
                // Rollback
                track.set(transport: nil, rtpSender: nil)
                try publisher.remove(track: transceiver.sender)
                // Rethrow
                throw error
            }

            let publication = LocalTrackPublication(info: addTrackResult.trackInfo, track: track, participant: self)

            add(publication: publication)

            // Notify didPublish
            delegates.notify(label: { "localParticipant.didPublish \(publication)" }) {
                $0.localParticipant?(self, didPublish: publication)
            }
            room.delegates.notify(label: { "localParticipant.didPublish \(publication)" }) {
                $0.room?(self.room, localParticipant: self, didPublish: publication)
            }

            log("[publish] success \(publication)", .info)

            return publication
        } catch {
            log("[publish] failed \(track), error: \(error)", .error)
            // Stop track when publish fails
            try await track.stop()
            // Rethrow
            throw error
        }
    }

    /// publish a new audio track to the Room
    @objc
    public func publish(audioTrack: LocalAudioTrack, publishOptions: AudioPublishOptions? = nil) async throws -> LocalTrackPublication {
        try await publish(track: audioTrack, publishOptions: publishOptions)
    }

    /// publish a new video track to the Room
    @objc
    public func publish(videoTrack: LocalVideoTrack, publishOptions: VideoPublishOptions? = nil) async throws -> LocalTrackPublication {
        try await publish(track: videoTrack, publishOptions: publishOptions)
    }

    @objc
    override public func unpublishAll(notify _notify: Bool = true) async {
        // Build a list of Publications
        let publications = _state.tracks.values.compactMap { $0 as? LocalTrackPublication }
        for publication in publications {
            do {
                try await unpublish(publication: publication, notify: _notify)
            } catch {
                log("Failed to unpublish track \(publication.sid) with error \(error)", .error)
            }
        }
    }

    /// unpublish an existing published track
    /// this will also stop the track
    @objc
    public func unpublish(publication: LocalTrackPublication, notify _notify: Bool = true) async throws {
        func _notifyDidUnpublish() async {
            guard _notify else { return }
            delegates.notify(label: { "localParticipant.didUnpublish \(publication)" }) {
                $0.localParticipant?(self, didUnpublish: publication)
            }
            room.delegates.notify(label: { "room.didUnpublish \(publication)" }) {
                $0.room?(self.room, localParticipant: self, didUnpublish: publication)
            }
        }

        let engine = room.engine

        // Remove the publication
        _state.mutate { $0.tracks.removeValue(forKey: publication.sid) }

        // If track is nil, only notify unpublish and return
        guard let track = publication.track as? LocalTrack else {
            return await _notifyDidUnpublish()
        }

        // Wait for track to stop (if required)
        if room._state.options.stopLocalTrackOnUnpublish {
            try await track.stop()
        }

        if let publisher = engine.publisher, let sender = track.rtpSender {
            try publisher.remove(track: sender)
            try await engine.publisherShouldNegotiate()
        }

        try await track.onUnpublish()

        await _notifyDidUnpublish()
    }

    /// Publish data to the other participants in the room
    ///
    /// Data is forwarded to each participant in the room. Each payload must not exceed 15k.
    /// - Parameters:
    ///   - data: Data to send
    ///   - reliability: Toggle between sending relialble vs lossy delivery.
    ///     For data that you need delivery guarantee (such as chat messages), use Reliable.
    ///     For data that should arrive as quickly as possible, but you are ok with dropped packets, use Lossy.
    ///   - destinations: SIDs of the participants who will receive the message. If empty, deliver to everyone
    @objc
    public func publish(data: Data,
                        reliability: Reliability = .reliable,
                        destinations: [Sid]? = nil,
                        topic: String? = nil,
                        options: DataPublishOptions? = nil) async throws
    {
        let options = options ?? room._state.options.defaultDataPublishOptions

        let userPacket = Livekit_UserPacket.with {
            $0.participantSid = self.sid
            $0.payload = data
            $0.destinationSids = destinations ?? options.destinations
            $0.topic = topic ?? options.topic ?? ""
        }

        try await room.engine.send(userPacket: userPacket, reliability: reliability)
    }

    /**
     * Control who can subscribe to LocalParticipant's published tracks.
     *
     * By default, all participants can subscribe. This allows fine-grained control over
     * who is able to subscribe at a participant and track level.
     *
     * Note: if access is given at a track-level (i.e. both ``allParticipantsAllowed`` and
     * ``ParticipantTrackPermission/allTracksAllowed`` are false), any newer published tracks
     * will not grant permissions to any participants and will require a subsequent
     * permissions update to allow subscription.
     *
     * - Parameter allParticipantsAllowed Allows all participants to subscribe all tracks.
     *  Takes precedence over ``participantTrackPermissions`` if set to true.
     *  By default this is set to true.
     * - Parameter participantTrackPermissions Full list of individual permissions per
     *  participant/track. Any omitted participants will not receive any permissions.
     */
    @objc
    public func setTrackSubscriptionPermissions(allParticipantsAllowed: Bool,
                                                trackPermissions: [ParticipantTrackPermission] = []) async throws
    {
        self.allParticipantsAllowed = allParticipantsAllowed
        self.trackPermissions = trackPermissions

        try await sendTrackSubscriptionPermissions()
    }

    /// Sets and updates the metadata of the local participant.
    ///
    /// Note: this requires `CanUpdateOwnMetadata` permission encoded in the token.
    public func set(metadata: String) async throws {
        // Mutate state to set metadata and copy name from state
        let name = _state.mutate {
            $0.metadata = metadata
            return $0.name
        }

        // TODO: Revert internal state on failure

        try await room.engine.signalClient.sendUpdateLocalMetadata(metadata, name: name ?? "")
    }

    /// Sets and updates the name of the local participant.
    ///
    /// Note: this requires `CanUpdateOwnMetadata` permission encoded in the token.
    public func set(name: String) async throws {
        // Mutate state to set name and copy metadata from state
        let metadata = _state.mutate {
            $0.name = name
            return $0.metadata
        }

        // TODO: Revert internal state on failure

        try await room.engine.signalClient.sendUpdateLocalMetadata(metadata ?? "", name: name)
    }

    func sendTrackSubscriptionPermissions() async throws {
        guard room.engine._state.connectionState == .connected else { return }

        try await room.engine.signalClient.sendUpdateSubscriptionPermission(allParticipants: allParticipantsAllowed,
                                                                            trackPermissions: trackPermissions)
    }

    func onSubscribedQualitiesUpdate(trackSid: String, subscribedQualities: [Livekit_SubscribedQuality]) {
        if !room._state.options.dynacast {
            return
        }

        guard let pub = getTrackPublication(sid: trackSid),
              let track = pub.track as? LocalVideoTrack,
              let sender = track.rtpSender
        else { return }

        let parameters = sender.parameters
        let encodings = parameters.encodings

        var hasChanged = false
        for quality in subscribedQualities {
            var rid: String
            switch quality.quality {
            case Livekit_VideoQuality.high: rid = "f"
            case Livekit_VideoQuality.medium: rid = "h"
            case Livekit_VideoQuality.low: rid = "q"
            default: continue
            }

            guard let encoding = encodings.first(where: { $0.rid == rid }) else {
                continue
            }

            if encoding.isActive != quality.enabled {
                hasChanged = true
                encoding.isActive = quality.enabled
                log("setting layer \(quality.quality) to \(quality.enabled)", .info)
            }
        }

        // Non simulcast streams don't have rids, handle here.
        if encodings.count == 1, subscribedQualities.count >= 1 {
            let encoding = encodings[0]
            let quality = subscribedQualities[0]

            if encoding.isActive != quality.enabled {
                hasChanged = true
                encoding.isActive = quality.enabled
                log("setting layer \(quality.quality) to \(quality.enabled)", .info)
            }
        }

        if hasChanged {
            sender.parameters = parameters
        }
    }

    override func set(permissions newValue: ParticipantPermissions) -> Bool {
        let didUpdate = super.set(permissions: newValue)

        if didUpdate {
            delegates.notify(label: { "participant.didUpdate permissions: \(newValue)" }) {
                $0.participant?(self, didUpdate: newValue)
            }
            room.delegates.notify(label: { "room.didUpdate permissions: \(newValue)" }) {
                $0.room?(self.room, participant: self, didUpdate: newValue)
            }
        }

        return didUpdate
    }
}

// MARK: - Session Migration

extension LocalParticipant {
    func publishedTracksInfo() -> [Livekit_TrackPublishedResponse] {
        _state.tracks.values.filter { $0.track != nil }
            .map { publication in
                Livekit_TrackPublishedResponse.with {
                    $0.cid = publication.track!.mediaTrack.trackId
                    if let info = publication._state.latestInfo {
                        $0.track = info
                    }
                }
            }
    }

    func republishTracks() async throws {
        let mediaTracks = _state.tracks.values.map { $0.track as? LocalTrack }.compactMap { $0 }

        await unpublishAll()

        for mediaTrack in mediaTracks {
            // Don't re-publish muted tracks
            if mediaTrack.muted { continue }
            try await publish(track: mediaTrack, publishOptions: mediaTrack.publishOptions)
        }
    }
}

// MARK: - Simplified API

public extension LocalParticipant {
    @objc
    @discardableResult
    func setCamera(enabled: Bool,
                   captureOptions: CameraCaptureOptions? = nil,
                   publishOptions: VideoPublishOptions? = nil) async throws -> LocalTrackPublication?
    {
        try await set(source: .camera,
                      enabled: enabled,
                      captureOptions: captureOptions,
                      publishOptions: publishOptions)
    }

    @objc
    @discardableResult
    func setMicrophone(enabled: Bool,
                       captureOptions: AudioCaptureOptions? = nil,
                       publishOptions: AudioPublishOptions? = nil) async throws -> LocalTrackPublication?
    {
        try await set(source: .microphone,
                      enabled: enabled,
                      captureOptions: captureOptions,
                      publishOptions: publishOptions)
    }

    /// Enable or disable screen sharing. This has different behavior depending on the platform.
    ///
    /// For iOS, this will use ``InAppScreenCapturer`` to capture in-app screen only due to Apple's limitation.
    /// If you would like to capture the screen when the app is in the background, you will need to create a "Broadcast Upload Extension".
    ///
    /// For macOS, this will use ``MacOSScreenCapturer`` to capture the main screen. ``MacOSScreenCapturer`` has the ability
    /// to capture other screens and windows. See ``MacOSScreenCapturer`` for details.
    ///
    /// For advanced usage, you can create a relevant ``LocalVideoTrack`` and call ``LocalParticipant/publishVideoTrack(track:publishOptions:)``.
    @objc
    @discardableResult
    func setScreenShare(enabled: Bool) async throws -> LocalTrackPublication? {
        try await set(source: .screenShareVideo, enabled: enabled)
    }

    @objc
    @discardableResult
    func set(source: Track.Source,
             enabled: Bool,
             captureOptions: CaptureOptions? = nil,
             publishOptions: PublishOptions? = nil) async throws -> LocalTrackPublication?
    {
        // Try to get existing publication
        if let publication = getTrackPublication(source: source) as? LocalTrackPublication {
            if enabled {
                try await publication.unmute()
                return publication
            } else {
                try await publication.mute()
                return publication
            }
        } else if enabled {
            // Try to create a new track
            if source == .camera {
                let localTrack = LocalVideoTrack.createCameraTrack(options: (captureOptions as? CameraCaptureOptions) ?? room._state.options.defaultCameraCaptureOptions)
                return try await publish(videoTrack: localTrack, publishOptions: publishOptions as? VideoPublishOptions)
            } else if source == .microphone {
                let localTrack = LocalAudioTrack.createTrack(options: (captureOptions as? AudioCaptureOptions) ?? room._state.options.defaultAudioCaptureOptions)
                return try await publish(audioTrack: localTrack, publishOptions: publishOptions as? AudioPublishOptions)
            } else if source == .screenShareVideo {
                #if os(iOS)
                //                var localTrack: LocalVideoTrack?
                //                let options = (captureOptions as? ScreenShareCaptureOptions) ?? room._state.options.defaultScreenShareCaptureOptions
                //                if options.useBroadcastExtension {
                //                    Task { @MainActor in
                //                        let screenShareExtensionId = Bundle.main.infoDictionary?[BroadcastScreenCapturer.kRTCScreenSharingExtension] as? String
                //                        RPSystemBroadcastPickerView.show(for: screenShareExtensionId,
                //                                                         showsMicrophoneButton: false)
                //                    }
                //                    localTrack = LocalVideoTrack.createBroadcastScreenCapturerTrack(options: options)
                //                } else {
                //                    localTrack = LocalVideoTrack.createInAppScreenShareTrack(options: options)
                //                }
                //
                //                if let localTrack = localTrack {
                //                    return publishVideoTrack(track: localTrack, publishOptions: publishOptions as? VideoPublishOptions).then(on: queue) { $0 }
                //                }
                #elseif os(macOS)
                    if #available(macOS 12.3, *) {
                        let mainDisplay = try await MacOSScreenCapturer.mainDisplaySource()
                        let track = LocalVideoTrack.createMacOSScreenShareTrack(source: mainDisplay,
                                                                                options: (captureOptions as? ScreenShareCaptureOptions) ?? self.room._state.options.defaultScreenShareCaptureOptions)
                        return try await publish(videoTrack: track, publishOptions: publishOptions as? VideoPublishOptions)
                    }
                #endif
            }
        }

        return nil
    }
}
