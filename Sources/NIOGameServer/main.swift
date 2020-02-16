import Foundation
import NIO

let gameRoom = GameRoom()
let tcpHandler = TCPHandler(in: gameRoom)
let udpHandler = UDPHandler(in: gameRoom)

let group = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)

let tcpBootstrap = ServerBootstrap(group: group)
    // Specify backlog and enable SO_REUSEADDR for the server itself
    .serverChannelOption(ChannelOptions.backlog, value: 256)
    .serverChannelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
    
    // Set the handlers that are applied to the accepted Channels
    .childChannelInitializer { channel in
        // Add handler that will buffer data until a \n is received
        channel.pipeline.addHandler(BackPressureHandler()).flatMap { v in
            // It's important we use the same handler for all accepted channels. The ChatHandler is thread-safe!
            channel.pipeline.addHandler(tcpHandler)
        }
}
    
    // Enable SO_REUSEADDR for the accepted Channels
    .childChannelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
    .childChannelOption(ChannelOptions.maxMessagesPerRead, value: 16)
    .childChannelOption(ChannelOptions.recvAllocator, value: AdaptiveRecvByteBufferAllocator())

var udpBootstrap = DatagramBootstrap(group: group)
    // Specify backlog and enable SO_REUSEADDR
    .channelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
    
    // Set the handlers that are applied to the bound channel
    .channelInitializer { channel in
        // Ensure we don't read faster than we can write by adding the BackPressureHandler into the pipeline.
        channel.pipeline.addHandler(udpHandler)
}

let tcpChannel = try tcpBootstrap.bind(host: "0.0.0.0", port: 20201).wait()
let udpChannel = try udpBootstrap.bind(host: "0.0.0.0", port: 20202).wait()

try tcpChannel.closeFuture.wait()
try udpChannel.closeFuture.wait()

defer {           
    try! group.syncShutdownGracefully()
}
