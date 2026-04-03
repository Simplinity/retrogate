import NIO
import NIOHTTP1
import Logging

/// The core HTTP proxy server built on SwiftNIO.
/// Listens for HTTP/1.0 and HTTP/1.1 proxy requests from vintage browsers.
public final class ProxyServer: Sendable {
    private let group: EventLoopGroup
    private let logger: Logger
    private let host: String
    private let port: Int
    
    public init(host: String = "0.0.0.0", port: Int = 8080) {
        self.host = host
        self.port = port
        self.group = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)
        var logger = Logger(label: "app.retrogate.proxy")
        logger.logLevel = .info
        self.logger = logger
    }
    
    /// Start the proxy server.
    public func start() async throws {
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(.backlog, value: 256)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.configureHTTPServerPipeline().flatMap {
                    channel.pipeline.addHandler(ProxyHTTPHandler(logger: self.logger))
                }
            }
            .childChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(.maxMessagesPerRead, value: 16)
        
        let channel = try await bootstrap.bind(host: host, port: port).get()
        logger.info("RetroGate proxy listening on \(host):\(port)")
        
        try await channel.closeFuture.get()
    }
    
    /// Stop the proxy server gracefully.
    public func stop() async throws {
        try await group.shutdownGracefully()
    }
}
