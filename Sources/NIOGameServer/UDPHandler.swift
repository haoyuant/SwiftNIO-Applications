//
//  UDPHandler.swift
//  NIOGameServer
//
//  Created by Haoyuan Tang on 13/2/20.
//

import Foundation
import NIO


final class UDPHandler: ChannelInboundHandler {
    public typealias InboundIn = AddressedEnvelope<ByteBuffer>
    public typealias OutboundOut = AddressedEnvelope<ByteBuffer>
    
    private var clientAddresses: [SocketAddress] = []
    private var room: GameRoom
    private var kcp: IKCPCB
    
    public init(in room: GameRoom) {
        self.room = room
        //init kcp
        self.kcp = IKCPCB(conv: 0x11223344, user: 0)
        _ = kcp.wndSize(sndwnd: 128, rcvwnd: 128)
        _ = kcp.nodelay(nodelay: 1, internalVal: 10, resend: 2, nc: 1)
        kcp.output = nil
    }
    
    func channelActive(context: ChannelHandlerContext) {
        
        context.eventLoop.scheduleRepeatedTask(initialDelay: TimeAmount.milliseconds(0), delay: TimeAmount.milliseconds(10)) {
            _ in
            self.kcp.update(current: uint32(truncating: NSNumber(value: Date().timeIntervalSince1970 * 1000)))
        }
        
        context.eventLoop.scheduleRepeatedTask(initialDelay: TimeAmount.seconds(0), delay: TimeAmount.milliseconds(20)) { _ in
            self.room.countdown -= 1

            guard !self.clientAddresses.isEmpty else {
                return
            }

            let message = "Current Room's countdown: \(self.room.countdown)"

            self.clientAddresses.forEach {
                _ in
                guard self.kcp.output != nil else {
                    return
                }
                _ = self.kcp.send(buffer: message.data(using: .utf8)!)
            }
        }
    }
    
    public func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        // As we are not really interested getting notified on success or failure we just pass nil as promise to
        // reduce allocations.
        let read = self.unwrapInboundIn(data)
        
        let hr = kcp.input(data: Data(read.data.getBytes(at: 0, length: read.data.readableBytes)!))
        guard hr >= 0 else { return }
        let data = kcp.recv(dataSize: read.data.readableBytes)
        guard let content = data else {
            return
        }
        
        let command = String(bytes: content, encoding: .utf8)?.trimmingCharacters(in: ["\n"])
        print(command)
//        return
        
        if let command = command, command == "JOIN" {
            if !clientAddresses.contains(read.remoteAddress) {
                clientAddresses.append(read.remoteAddress)

                self.kcp.output = {
                    buf, _, _ in
                    
                    // Set the transmission data.
                    var buffer = context.channel.allocator.buffer(capacity: buf.count)
                    buffer.writeBytes(buf)
                    
                    // Forward the data.
                    let envolope = AddressedEnvelope<ByteBuffer>(remoteAddress: read.remoteAddress, data: buffer)
                    
                    context.writeAndFlush(self.wrapOutboundOut(envolope), promise: nil)
                    
                    return 0
                }
            }
        }

        
        let message = "A new udp client [\(read.remoteAddress.description)] has joined in!"
        
        clientAddresses.forEach {
            _ in
            _ = self.kcp.send(buffer: message.data(using: .utf8)!)
        }
    }
    
    public func channelReadComplete(context: ChannelHandlerContext) {
        // As we are not really interested getting notified on success or failure we just pass nil as promise to
        // reduce allocations.
        context.flush()
    }
    
    public func errorCaught(context: ChannelHandlerContext, error: Error) {
        print("error: ", error)
        
        // As we are not really interested getting notified on success or failure we just pass nil as promise to
        // reduce allocations.
        context.close(promise: nil)
    }
}
