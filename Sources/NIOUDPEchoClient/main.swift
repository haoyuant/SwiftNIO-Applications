//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2017-2019 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//
import NIO
import Foundation

print("Please enter line to send to the server")
let line = readLine(strippingNewline: true)!

private final class EchoHandler: ChannelInboundHandler {
    public typealias InboundIn = AddressedEnvelope<ByteBuffer>
    public typealias OutboundOut = AddressedEnvelope<ByteBuffer>
    private var kcp: IKCPCB
    
    private let remoteAddressInitializer: () throws -> SocketAddress
    
    init(remoteAddressInitializer: @escaping () throws -> SocketAddress) {
        self.remoteAddressInitializer = remoteAddressInitializer

        self.kcp = IKCPCB(conv: 0x11223344, user: 1)
        _ = kcp.wndSize(sndwnd: 128, rcvwnd: 128)
        _ = kcp.nodelay(nodelay: 1, internalVal: 10, resend: 2, nc: 1)
        kcp.output = nil
    }
    
    public func channelActive(context: ChannelHandlerContext) {
        do {
            // Channel is available. It's time to send the message to the server to initialize the ping-pong sequence.
            
            // Get the server address.
            let remoteAddress = try self.remoteAddressInitializer()
            
            if kcp.output == nil {
                kcp.output = {
                    buf, _, _ in
                    
                    // Set the transmission data.
                    var buffer = context.channel.allocator.buffer(capacity: buf.count)
                    buffer.writeBytes(buf)
                    
                    // Forward the data.
                    let envolope = AddressedEnvelope<ByteBuffer>(remoteAddress: remoteAddress, data: buffer)
                    
                    context.writeAndFlush(self.wrapOutboundOut(envolope), promise: nil)
                    
                    return 0
                }
            }

            context.eventLoop.scheduleRepeatedTask(initialDelay: TimeAmount.milliseconds(0), delay: TimeAmount.milliseconds(10)) {
                _ in
                self.kcp.update(current: uint32(truncating: NSNumber(value: Date().timeIntervalSince1970 * 1000)))
            }
            
            _ = kcp.send(buffer: line.data(using: .utf8)!)
            
        } catch {
            print("Could not resolve remote address")
        }
    }
    
    private var count = 0
    
    public func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let envelope = self.unwrapInboundIn(data)
        var byteBuffer = envelope.data
        
        let hr = kcp.input(data: Data(byteBuffer.getBytes(at: 0, length: byteBuffer.readableBytes)!))
           guard hr >= 0 else { return }
           let data = kcp.recv(dataSize: byteBuffer.readableBytes)
           guard let content = data else {
               return
           }
        
        if let string = String(bytes: content, encoding: .utf8) {
            count += 1
            print("Received[\(count)]: '\(string)'")
        } else {
            print("Received the line back from the server, closing channel.")
        }
    }
    
    public func errorCaught(context: ChannelHandlerContext, error: Error) {
        print("error: ", error)
        
        // As we are not really interested getting notified on success or failure we just pass nil as promise to
        // reduce allocations.
        context.close(promise: nil)
    }
}

// First argument is the program path
let arguments = CommandLine.arguments
let arg1 = arguments.dropFirst().first
let arg2 = arguments.dropFirst(2).first
let arg3 = arguments.dropFirst(3).first

// If only writing to the destination address, bind to local port 0 and address 0.0.0.0 or ::.
let defaultHost = "127.0.0.1"
// If the server and the client are running on the same computer, these will need to differ from each other.
let defaultServerPort: Int = 9999
let defaultListeningPort: Int = 8888

enum ConnectTo {
    case ip(host: String, sendPort: Int, listeningPort: Int)
    case unixDomainSocket(sendPath: String, listeningPath: String)
}

let connectTarget: ConnectTo

switch (arg1, arg1.flatMap(Int.init), arg2, arg2.flatMap(Int.init), arg3.flatMap(Int.init)) {
case (.some(let h), .none , _, .some(let sp), .some(let lp)):
    /* We received three arguments (String Int Int), let's interpret that as a server host with a server port and a local listening port */
    connectTarget = .ip(host: h, sendPort: sp, listeningPort: lp)
case (.some(let sp), .none , .some(let lp), .none, _):
    /* We received two arguments (String String), let's interpret that as sending socket path and listening socket path  */
    assert(sp != lp, "The sending and listening sockets should differ.")
    connectTarget = .unixDomainSocket(sendPath: sp, listeningPath: lp)
case (_, .some(let sp), _, .some(let lp), _):
    /* We received two argument (Int Int), let's interpret that as the server port and a listening port on the default host. */
    connectTarget = .ip(host: defaultHost, sendPort: sp, listeningPort: lp)
default:
    connectTarget = .ip(host: defaultHost, sendPort: defaultServerPort, listeningPort: defaultListeningPort)
}

let remoteAddress = { () -> SocketAddress in
    switch connectTarget {
    case .ip(let host, let sendPort, _):
        return try SocketAddress.makeAddressResolvingHost(host, port: sendPort)
    case .unixDomainSocket(let sendPath, _):
        return try SocketAddress(unixDomainSocketPath: sendPath)
    }
}

let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
let bootstrap = DatagramBootstrap(group: group)
    // Enable SO_REUSEADDR.
    .channelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
    .channelInitializer { channel in
        channel.pipeline.addHandler(EchoHandler(remoteAddressInitializer: remoteAddress))
}
defer {
    try! group.syncShutdownGracefully()
}

let channel = try { () -> Channel in
    switch connectTarget {
    case .ip(let host, _, let listeningPort):
        return try bootstrap.bind(host: host, port: listeningPort).wait()
    case .unixDomainSocket(_, let listeningPath):
        return try bootstrap.bind(unixDomainSocketPath: listeningPath).wait()
    }
    }()

// Will be closed after we echo-ed back to the server.
try channel.closeFuture.wait()

print("Client closed")
