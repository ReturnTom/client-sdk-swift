/*
 * Copyright 2024 LiveKit
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
import SwiftProtobuf

@_implementationOnly import WebRTC

actor Transport: NSObject, Loggable {
    // MARK: - Types

    typealias OnOfferBlock = (RTCSessionDescription) async throws -> Void

    // MARK: - Public

    nonisolated let target: Livekit_SignalTarget
    nonisolated let isPrimary: Bool

    nonisolated var connectionState: RTCPeerConnectionState {
        DispatchQueue.liveKitWebRTC.sync { _pc.connectionState }
    }

    nonisolated var isConnected: Bool {
        connectionState == .connected
    }

    nonisolated var localDescription: RTCSessionDescription? {
        DispatchQueue.liveKitWebRTC.sync { _pc.localDescription }
    }

    nonisolated var remoteDescription: RTCSessionDescription? {
        DispatchQueue.liveKitWebRTC.sync { _pc.remoteDescription }
    }

    nonisolated var signalingState: RTCSignalingState {
        DispatchQueue.liveKitWebRTC.sync { _pc.signalingState }
    }

    // MARK: - Private

    private let _delegate = AsyncSerialDelegate<TransportDelegate>()
    private let _queue = DispatchQueue(label: "LiveKitSDK.transport", qos: .default)
    private let _debounce = Debounce(delay: 0.1)

    private var _reNegotiate: Bool = false
    private var _onOffer: OnOfferBlock?
    private var _isRestartingIce: Bool = false

    // forbid direct access to PeerConnection
    private let _pc: RTCPeerConnection

    private lazy var _iceCandidatesQueue = QueueActor<RTCIceCandidate>(onProcess: { [weak self] iceCandidate in
        guard let self else { return }

        do {
            try await self._pc.add(iceCandidate)
        } catch {
            self.log("Failed to add(iceCandidate:) with error: \(error)", .error)
        }
    })

    init(config: RTCConfiguration,
         target: Livekit_SignalTarget,
         primary: Bool,
         delegate: TransportDelegate) throws
    {
        // try create peerConnection
        guard let pc = Engine.createPeerConnection(config,
                                                   constraints: .defaultPCConstraints)
        else {
            // log("[WebRTC] Failed to create PeerConnection", .error)
            throw LiveKitError(.webRTC, message: "Failed to create PeerConnection")
        }

        self.target = target
        isPrimary = primary
        _pc = pc

        super.init()
        log()

        DispatchQueue.liveKitWebRTC.sync { pc.delegate = self }
        _delegate.set(delegate: delegate)
    }

    deinit {
        log()
    }

    func negotiate() async {
        await _debounce.schedule {
            try await self.createAndSendOffer()
        }
    }

    func set(onOfferBlock block: @escaping OnOfferBlock) {
        _onOffer = block
    }

    func setIsRestartingIce() {
        _isRestartingIce = true
    }

    func add(iceCandidate candidate: RTCIceCandidate) async throws {
        await _iceCandidatesQueue.process(candidate, if: remoteDescription != nil && !_isRestartingIce)
    }

    func set(remoteDescription sd: RTCSessionDescription) async throws {
        try await _pc.setRemoteDescription(sd)

        await _iceCandidatesQueue.resume()

        _isRestartingIce = false

        if _reNegotiate {
            _reNegotiate = false
            try await createAndSendOffer()
        }
    }

    func set(configuration: RTCConfiguration) throws {
        if !_pc.setConfiguration(configuration) {
            throw LiveKitError(.webRTC, message: "Failed to set configuration")
        }
    }

    func createAndSendOffer(iceRestart: Bool = false) async throws {
        guard let _onOffer else {
            log("_onOffer is nil", .warning)
            return
        }

        var constraints = [String: String]()
        if iceRestart {
            log("Restarting ICE...")
            constraints[kRTCMediaConstraintsIceRestart] = kRTCMediaConstraintsValueTrue
            _isRestartingIce = true
        }

        if signalingState == .haveLocalOffer, !(iceRestart && remoteDescription != nil) {
            _reNegotiate = true
            return
        }

        // Actually negotiate
        func _negotiateSequence() async throws {
            let offer = try await createOffer(for: constraints)
            try await _pc.setLocalDescription(offer)
            try await _onOffer(offer)
        }

        if signalingState == .haveLocalOffer, iceRestart, let sd = remoteDescription {
            try await set(remoteDescription: sd)
            return try await _negotiateSequence()
        }

        try await _negotiateSequence()
    }

    func close() async {
        // prevent debounced negotiate firing
        await _debounce.cancel()

        DispatchQueue.liveKitWebRTC.sync {
            // Stop listening to delegate
            self._pc.delegate = nil
            // Remove all senders (if any)
            for sender in self._pc.senders {
                self._pc.removeTrack(sender)
            }

            self._pc.close()
        }
    }
}

// MARK: - Stats

extension Transport {
    func statistics(for sender: RTCRtpSender) async -> RTCStatisticsReport {
        await _pc.statistics(for: sender)
    }

    func statistics(for receiver: RTCRtpReceiver) async -> RTCStatisticsReport {
        await _pc.statistics(for: receiver)
    }
}

// MARK: - RTCPeerConnectionDelegate

extension Transport: RTCPeerConnectionDelegate {
    nonisolated func peerConnection(_: RTCPeerConnection, didChange state: RTCPeerConnectionState) {
        log("[Connect] Transport(\(target)) did update state: \(state.description)")
        _delegate.notifyAsync { await $0.transport(self, didUpdateState: state) }
    }

    nonisolated func peerConnection(_: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        _delegate.notifyAsync { await $0.transport(self, didGenerateIceCandidate: candidate) }
    }

    nonisolated func peerConnectionShouldNegotiate(_: RTCPeerConnection) {
        log("ShouldNegotiate for \(target)")
        _delegate.notifyAsync { await $0.transportShouldNegotiate(self) }
    }

    nonisolated func peerConnection(_: RTCPeerConnection, didAdd rtpReceiver: RTCRtpReceiver, streams: [RTCMediaStream]) {
        guard let track = rtpReceiver.track else {
            log("Track is empty for \(target)", .warning)
            return
        }

        log("type: \(type(of: track)), track.id: \(track.trackId), streams: \(streams.map { "Stream(hash: \($0.hash), id: \($0.streamId), videoTracks: \($0.videoTracks.count), audioTracks: \($0.audioTracks.count))" })")
        _delegate.notifyAsync { await $0.transport(self, didAddTrack: track, rtpReceiver: rtpReceiver, streams: streams) }
    }

    nonisolated func peerConnection(_: RTCPeerConnection, didRemove rtpReceiver: RTCRtpReceiver) {
        guard let track = rtpReceiver.track else {
            log("Track is empty for \(target)", .warning)
            return
        }

        log("didRemove track: \(track.trackId)")
        _delegate.notifyAsync { await $0.transport(self, didRemoveTrack: track) }
    }

    nonisolated func peerConnection(_: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {
        log("Received data channel \(dataChannel.label) for \(target)")
        _delegate.notifyAsync { await $0.transport(self, didOpenDataChannel: dataChannel) }
    }

    nonisolated func peerConnection(_: RTCPeerConnection, didChange _: RTCIceConnectionState) {}
    nonisolated func peerConnection(_: RTCPeerConnection, didRemove _: RTCMediaStream) {}
    nonisolated func peerConnection(_: RTCPeerConnection, didChange _: RTCSignalingState) {}
    nonisolated func peerConnection(_: RTCPeerConnection, didAdd _: RTCMediaStream) {}
    nonisolated func peerConnection(_: RTCPeerConnection, didChange _: RTCIceGatheringState) {}
    nonisolated func peerConnection(_: RTCPeerConnection, didRemove _: [RTCIceCandidate]) {}
}

// MARK: - Private

private extension Transport {
    func createOffer(for constraints: [String: String]? = nil) async throws -> RTCSessionDescription {
        let mediaConstraints = RTCMediaConstraints(mandatoryConstraints: constraints,
                                                     optionalConstraints: nil)

        return try await _pc.offer(for: mediaConstraints)
    }
}

// MARK: - Internal

extension Transport {
    func createAnswer(for constraints: [String: String]? = nil) async throws -> RTCSessionDescription {
        let mediaConstraints = RTCMediaConstraints(mandatoryConstraints: constraints,
                                                     optionalConstraints: nil)

        return try await _pc.answer(for: mediaConstraints)
    }

    func set(localDescription sd: RTCSessionDescription) async throws {
        try await _pc.setLocalDescription(sd)
    }

    func addTransceiver(with track: RTCMediaStreamTrack,
                        transceiverInit: RTCRtpTransceiverInit) throws -> RTCRtpTransceiver
    {
        guard let transceiver = DispatchQueue.liveKitWebRTC.sync(execute: { _pc.addTransceiver(with: track, init: transceiverInit) }) else {
            throw LiveKitError(.webRTC, message: "Failed to add transceiver")
        }

        return transceiver
    }

    func remove(track sender: RTCRtpSender) throws {
        guard DispatchQueue.liveKitWebRTC.sync(execute: { _pc.removeTrack(sender) }) else {
            throw LiveKitError(.webRTC, message: "Failed to remove track")
        }
    }

    func dataChannel(for label: String,
                     configuration: RTCDataChannelConfiguration,
                     delegate: RTCDataChannelDelegate? = nil) -> RTCDataChannel?
    {
        let result = DispatchQueue.liveKitWebRTC.sync { _pc.dataChannel(forLabel: label, configuration: configuration) }
        result?.delegate = delegate
        return result
    }
}
