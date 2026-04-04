import NIO
import NIOConcurrencyHelpers
import NIOHTTP1
import Logging

/// Thread-safe shared configuration box that allows live updates
/// from the UI while the server is running.
public final class SharedConfiguration: @unchecked Sendable {
    private let lock = NIOLock()
    private var _value: ProxyConfiguration

    public init(_ value: ProxyConfiguration) {
        self._value = value
    }

    public var value: ProxyConfiguration {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }
}

/// The core HTTP proxy server built on SwiftNIO.
/// Listens for HTTP/1.0 and HTTP/1.1 proxy requests from vintage browsers.
public final class ProxyServer: @unchecked Sendable {
    private let group: EventLoopGroup
    private let logger: Logger
    private let host: String
    private let port: Int
    public let sharedConfig: SharedConfiguration
    public let temporalCache: TemporalCache
    public let redirectTracker: RedirectTracker
    public let responseCache: ResponseCache
    private var serverChannel: Channel?

    public init(host: String = "0.0.0.0", port: Int = 8080, configuration: ProxyConfiguration = ProxyConfiguration()) {
        self.host = host
        self.port = port
        self.sharedConfig = SharedConfiguration(configuration)
        self.temporalCache = TemporalCache()
        self.redirectTracker = RedirectTracker()
        self.responseCache = ResponseCache()
        self.group = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)
        var logger = Logger(label: "app.retrogate.proxy")
        logger.logLevel = .info
        self.logger = logger
    }

    /// Start the proxy server. Returns after binding (does not block until shutdown).
    public func start() async throws {
        let sharedConfig = self.sharedConfig
        let temporalCache = self.temporalCache
        let redirectTracker = self.redirectTracker
        let responseCache = self.responseCache
        let logger = self.logger
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(.backlog, value: 256)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.configureHTTPServerPipeline().flatMap {
                    channel.pipeline.addHandler(ProxyHTTPHandler(logger: logger, sharedConfig: sharedConfig, temporalCache: temporalCache, redirectTracker: redirectTracker, responseCache: responseCache))
                }
            }
            .childChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(.maxMessagesPerRead, value: 16)

        let channel = try await bootstrap.bind(host: host, port: port).get()
        self.serverChannel = channel
        logger.info("RetroGate proxy listening on \(host):\(port)")
    }

    /// Wait until the server is shut down.
    public func waitForClose() async throws {
        try await serverChannel?.closeFuture.get()
    }

    /// Stop the proxy server gracefully.
    public func stop() async throws {
        try await serverChannel?.close()
        try await group.shutdownGracefully()
        serverChannel = nil
    }
}
