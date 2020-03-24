//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2019 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import NIO

struct SSHConnectionStateMachine {
    enum State {
        /// The connection has not begun.
        case idle(IdleState)

        /// We have sent our version message.
        case sentVersion(SentVersionState)

        /// We are in the process of actively performing a key exchange operation. Neither side has sent its newKeys message yet.
        case keyExchange(KeyExchangeState)

        /// We are performing a key exchange. We have sent our newKeys message, but not yet received one from our peer.
        case sentNewKeys(SentNewKeysState)

        /// We are performing a key exchange. We have received the peer newKeys message, but not yet sent one ourselves.
        case receivedNewKeys(ReceivedNewKeysState)

        /// We are currently performing a user authentication.
        case userAuthentication(UserAuthenticationState)

        case channel
    }

    /// The state of this state machine.
    private var state: State

    init(role: SSHConnectionRole) {
        self.state = .idle(IdleState(role: role))
    }

    func start() -> SSHMultiMessage {
        switch self.state {
        case .idle:
            return SSHMultiMessage(SSHMessage.version(Constants.version))
        case .sentVersion, .keyExchange, .sentNewKeys, .receivedNewKeys, .userAuthentication, .channel:
            preconditionFailure("Cannot call start twice, state \(self.state)")
        }
    }

    mutating func bufferInboundData(_ data: inout ByteBuffer) {
        switch self.state {
        case .idle:
            preconditionFailure("Cannot receive inbound data in idle state")
        case .sentVersion(var state):
            state.parser.append(bytes: &data)
            self.state = .sentVersion(state)
        case .keyExchange(var state):
            state.parser.append(bytes: &data)
            self.state = .keyExchange(state)
        case .receivedNewKeys(var state):
            state.parser.append(bytes: &data)
            self.state = .receivedNewKeys(state)
        case .sentNewKeys(var state):
            state.parser.append(bytes: &data)
            self.state = .sentNewKeys(state)
        case .userAuthentication(var state):
            state.parser.append(bytes: &data)
            self.state = .userAuthentication(state)
        case .channel:
            break
        }
    }

    mutating func processInboundMessage(allocator: ByteBufferAllocator,
                                        loop: EventLoop,
                                        userAuthDelegate: UserAuthDelegate) throws -> StateMachineInboundProcessResult? {
        switch self.state {
        case .idle:
            preconditionFailure("Received messages before sending our first message.")
        case .sentVersion(var state):
            guard let message = try state.parser.nextPacket() else {
                return nil
            }

            switch message {
            case .version(let version):
                try state.receiveVersionMessage(version)
                var newState = KeyExchangeState(sentVersionState: state, allocator: allocator, remoteVersion: version)
                let message = newState.keyExchangeStateMachine.startKeyExchange()
                self.state = .keyExchange(newState)
                return .emitMessage(message)
            default:
                throw NIOSSHError.protocolViolation(protocolName: "transport", violation: "Did not receive version message")
            }
        case .keyExchange(var state):
            guard let message = try state.parser.nextPacket() else {
                return nil
            }

            switch message {
            case .keyExchange(let message):
                let result = try state.receiveKeyExchangeMessage(message)
                self.state = .keyExchange(state)
                return result
            case .keyExchangeInit(let message):
                let result = try state.receiveKeyExchangeInitMessage(message)
                self.state = .keyExchange(state)
                return result
            case .keyExchangeReply(let message):
                let result = try state.receiveKeyExchangeReplyMessage(message)
                self.state = .keyExchange(state)
                return result
            case .newKeys:
                try state.receiveNewKeysMessage()
                let newState = ReceivedNewKeysState(keyExchangeState: state, delegate: userAuthDelegate, loop: loop)
                let possibleMessage = newState.userAuthStateMachine.beginAuthentication()
                self.state = .receivedNewKeys(newState)

                if let message = possibleMessage {
                    return .emitMessage(SSHMultiMessage(.serviceRequest(message)))
                } else {
                    return .noMessage
                }
            default:
                // TODO: enforce RFC 4253:
                //
                // > Once a party has sent a SSH_MSG_KEXINIT message for key exchange or
                // > re-exchange, until it has sent a SSH_MSG_NEWKEYS message (Section
                // > 7.3), it MUST NOT send any messages other than:
                // >
                // > o  Transport layer generic messages (1 to 19) (but
                // >    SSH_MSG_SERVICE_REQUEST and SSH_MSG_SERVICE_ACCEPT MUST NOT be
                // >    sent);
                // >
                // > o  Algorithm negotiation messages (20 to 29) (but further
                // >    SSH_MSG_KEXINIT messages MUST NOT be sent);
                // >
                // > o  Specific key exchange method messages (30 to 49).
                //
                // We should enforce that, but right now we don't have a good mechanism by which to do so.
                return .noMessage
            }
        case .sentNewKeys(var state):
            guard let message = try state.parser.nextPacket() else {
                return nil
            }

            switch message {
            case .keyExchange(let message):
                let result = try state.receiveKeyExchangeMessage(message)
                self.state = .sentNewKeys(state)
                return result
            case .keyExchangeInit(let message):
                let result = try state.receiveKeyExchangeInitMessage(message)
                self.state = .sentNewKeys(state)
                return result
            case .keyExchangeReply(let message):
                let result = try state.receiveKeyExchangeReplyMessage(message)
                self.state = .sentNewKeys(state)
                return result
            case .newKeys:
                try state.receiveNewKeysMessage()
                let newState = UserAuthenticationState(sentNewKeysState: state)
                let possibleMessage = newState.userAuthStateMachine.beginAuthentication()
                self.state = .userAuthentication(newState)

                if let message = possibleMessage {
                    return .emitMessage(SSHMultiMessage(.serviceRequest(message)))
                } else {
                    return .noMessage
                }
                
            default:
                // TODO: enforce RFC 4253:
                //
                // > Once a party has sent a SSH_MSG_KEXINIT message for key exchange or
                // > re-exchange, until it has sent a SSH_MSG_NEWKEYS message (Section
                // > 7.3), it MUST NOT send any messages other than:
                // >
                // > o  Transport layer generic messages (1 to 19) (but
                // >    SSH_MSG_SERVICE_REQUEST and SSH_MSG_SERVICE_ACCEPT MUST NOT be
                // >    sent);
                // >
                // > o  Algorithm negotiation messages (20 to 29) (but further
                // >    SSH_MSG_KEXINIT messages MUST NOT be sent);
                // >
                // > o  Specific key exchange method messages (30 to 49).
                //
                // We should enforce that, but right now we don't have a good mechanism by which to do so.
                return .noMessage
            }

        case .receivedNewKeys(var state):
            // In this state we tolerate receiving service request messages. As we haven't sent newKeys, we cannot
            // send any user auth messages yet, so by definition we can't receive any other user auth message.
            guard let message = try state.parser.nextPacket() else {
                return nil
            }

            switch message {
            case .serviceRequest(let message):
                let result = try state.receiveServiceRequest(message)
                self.state = .receivedNewKeys(state)
                return result

            case .serviceAccept, .userAuthRequest, .userAuthSuccess, .userAuthFailure:
                throw NIOSSHError.protocolViolation(protocolName: "user auth", violation: "Unexpected user auth message: \(message)")

            default:
                throw NIOSSHError.protocolViolation(protocolName: "user auth", violation: "Unexpected inbound message: \(message)")
            }

        case .userAuthentication(var state):
            // In this state we tolerate receiving user auth messages.
            guard let message = try state.parser.nextPacket() else {
                return nil
            }

            switch message {
            case .serviceRequest(let message):
                let result = try state.receiveServiceRequest(message)
                self.state = .userAuthentication(state)
                return result

            case .serviceAccept(let message):
                let result = try state.receiveServiceAccept(message)
                self.state = .userAuthentication(state)
                return result

            case .userAuthRequest(let message):
                let result = try state.receiveUserAuthRequest(message)
                self.state = .userAuthentication(state)
                return result

            case .userAuthSuccess:
                let result = try state.receiveUserAuthSuccess()
                // Hey, auth succeeded!
                self.state = .channel
                return result

            case .userAuthFailure(let message):
                let result = try state.receiveUserAuthFailure(message)
                self.state = .userAuthentication(state)
                return result

            default:
                throw NIOSSHError.protocolViolation(protocolName: "user auth", violation: "Unexpected inbound message: \(message)")
            }

        case .channel:
            // TODO: we now have keys
            return .noMessage
        }
    }

    mutating func processOutboundMessage(_ message: SSHMessage,
                                         buffer: inout ByteBuffer,
                                         allocator: ByteBufferAllocator,
                                         loop: EventLoop,
                                         userAuthDelegate: UserAuthDelegate) throws {
        switch self.state {
        case .idle(var state):
            switch message {
            case .version:
                try state.serializer.serialize(message: message, to: &buffer)
                self.state = .sentVersion(.init(idleState: state, allocator: allocator))
            default:
                preconditionFailure("First message sent must be version, not \(message)")
            }

        case .sentVersion:
            // We can't send anything else now.
            // TODO(cory): We could refactor the key exchange state machine to accept the delayed version from the
            // remote peer, and then we unlock the ability to remove another RTT to the remote peer.
            preconditionFailure("Cannot send other messages before receiving version.")

        case .keyExchange(var kex):
            switch message {
            case .keyExchange(let keyExchangeMessage):
                try kex.writeKeyExchangeMessage(keyExchangeMessage, into: &buffer)
                self.state = .keyExchange(kex)
            case .keyExchangeInit(let kexInit):
                try kex.writeKeyExchangeInitMessage(kexInit, into: &buffer)
                self.state = .keyExchange(kex)
            case .keyExchangeReply(let kexReply):
                try kex.writeKeyExchangeReplyMessage(kexReply, into: &buffer)
                self.state = .keyExchange(kex)
            case .newKeys:
                try kex.writeNewKeysMessage(into: &buffer)
                self.state = .sentNewKeys(.init(keyExchangeState: kex, delegate: userAuthDelegate, loop: loop))

            default:
                throw NIOSSHError.protocolViolation(protocolName: "key exchange", violation: "Sent unexpected message type: \(message)")
            }

        case .receivedNewKeys(var kex):
            switch message {
            case .keyExchange(let keyExchangeMessage):
                try kex.writeKeyExchangeMessage(keyExchangeMessage, into: &buffer)
                self.state = .receivedNewKeys(kex)
            case .keyExchangeInit(let kexInit):
                try kex.writeKeyExchangeInitMessage(kexInit, into: &buffer)
                self.state = .receivedNewKeys(kex)
            case .keyExchangeReply(let kexReply):
                try kex.writeKeyExchangeReplyMessage(kexReply, into: &buffer)
                self.state = .receivedNewKeys(kex)
            case .newKeys:
                try kex.writeNewKeysMessage(into: &buffer)
                self.state = .userAuthentication(.init(receivedNewKeysState: kex))

            default:
                throw NIOSSHError.protocolViolation(protocolName: "key exchange", violation: "Sent unexpected message type: \(message)")
            }

        case .sentNewKeys(var state):
            // In this state we tolerate sending service request. As we cannot have received any user auth messages
            // (we're still waiting for newKeys), we cannot possibly send any other user auth message
            switch message {
            case .serviceRequest(let message):
                try state.writeServiceRequest(message, into: &buffer)
                self.state = .sentNewKeys(state)

            case .serviceAccept, .userAuthRequest, .userAuthSuccess, .userAuthFailure:
                throw NIOSSHError.protocolViolation(protocolName: "user auth", violation: "Cannot send \(message) before receiving newKeys")

            default:
                throw NIOSSHError.protocolViolation(protocolName: "user auth", violation: "Sent unexpected message type: \(message)")
            }

        case .userAuthentication(var state):
            // In this state we tolerate sending user auth messages.
            switch message {
            case .serviceRequest(let message):
                try state.writeServiceRequest(message, into: &buffer)
                self.state = .userAuthentication(state)

            case .serviceAccept(let message):
                try state.writeServiceAccept(message, into: &buffer)
                self.state = .userAuthentication(state)

            case .userAuthRequest(let message):
                try state.writeUserAuthRequest(message, into: &buffer)
                self.state = .userAuthentication(state)

            case .userAuthSuccess:
                try state.writeUserAuthSuccess(into: &buffer)
                // Ok we're good to go!
                self.state = .channel

            case .userAuthFailure(let message):
                try state.writeUserAuthFailure(message, into: &buffer)
                self.state = .userAuthentication(state)

            default:
                throw NIOSSHError.protocolViolation(protocolName: "user auth", violation: "Sent unexpected message type: \(message)")
            }

        case .channel:
            // We can't send anything in these states.
            break
        }
    }
}


extension SSHConnectionStateMachine {
    /// The result of spinning the state machine with an inbound message.
    ///
    /// When the state machine processes a message, several things may happen. Firstly, it may generate an
    /// automatic message that should be sent. Secondly, it may generate a possibility of having a message in
    /// future. Thirdly, it may generate nothing.
    enum StateMachineInboundProcessResult {
        case emitMessage(SSHMultiMessage)
        case possibleFutureMessage(EventLoopFuture<SSHMultiMessage?>)
        case noMessage
    }
}