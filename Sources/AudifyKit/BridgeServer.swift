import Foundation
import Network
import OSLog

/// A browser connected to Audify.
public struct BridgeClient: Identifiable, Hashable, Sendable {
    public let id: UUID
    public var browserName: String
    public var isAuthenticated: Bool
    public var connectedAt: Date
}

/// Loopback-only WebSocket server that browser extensions talk to.
///
/// Why a socket and not native messaging: native messaging would have Chrome spawn a helper
/// process that then needs its own channel back into the running menu-bar app. A loopback socket
/// keeps it to one hop, works identically across Chrome, Edge, Brave, Vivaldi and Firefox, and
/// survives the app and the browser restarting in either order.
///
/// Security posture: bound to 127.0.0.1 so nothing off-machine can reach it, and a connection must
/// present the pairing token from Settings within `authenticationTimeout` or it is dropped.
@MainActor
public final class BridgeServer: ObservableObject {
    public enum State: Equatable {
        case stopped
        case listening(port: UInt16)
        case failed(String)
    }

    @Published public private(set) var state: State = .stopped
    @Published public private(set) var clients: [BridgeClient] = []

    /// Called with (clientID, tabs) whenever a browser reports its tab list.
    public var onTabs: ((UUID, [BridgeTabPayload]) -> Void)?
    public var onClientDisconnected: ((UUID) -> Void)?
    /// Supplies the expected pairing token at connection time.
    public var tokenProvider: (() -> String)?
    /// Supplies the payload for the `welcome` message.
    public var welcomeProvider: (() -> BridgeOutbound)?

    private let authenticationTimeout: TimeInterval = 5
    private let queue = DispatchQueue(label: "com.audify.bridge", qos: .utility)
    private let log = Logger(subsystem: AudifyLog.subsystem, category: "bridge")

    private var listener: NWListener?
    private var connections: [UUID: NWConnection] = [:]
    private var authenticated: Set<UUID> = []
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init() {}

    // MARK: - Lifecycle

    public func start(port: Int) {
        stop()
        guard let portValue = NWEndpoint.Port(rawValue: UInt16(clamping: port)) else {
            state = .failed("Invalid port \(port)")
            return
        }

        let websocket = NWProtocolWebSocket.Options()
        websocket.autoReplyPing = true

        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.includePeerToPeer = false
        // Binding explicitly to loopback is what keeps this off the network.
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: portValue)
        parameters.defaultProtocolStack.applicationProtocols.insert(websocket, at: 0)

        do {
            let listener = try NWListener(using: parameters)
            self.listener = listener

            listener.stateUpdateHandler = { [weak self] newState in
                Task { @MainActor in self?.handleListenerState(newState, port: portValue.rawValue) }
            }
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in self?.accept(connection) }
            }
            listener.start(queue: queue)
        } catch {
            log.error("Bridge listener failed: \(String(describing: error))")
            state = .failed(error.localizedDescription)
        }
    }

    public func stop() {
        for connection in connections.values { connection.cancel() }
        connections.removeAll()
        authenticated.removeAll()
        clients.removeAll()
        listener?.cancel()
        listener = nil
        state = .stopped
    }

    private func handleListenerState(_ newState: NWListener.State, port: UInt16) {
        switch newState {
        case .ready:
            state = .listening(port: port)
            log.info("Bridge listening on 127.0.0.1:\(port)")
        case let .failed(error):
            state = .failed(Self.describe(error))
            log.error("Bridge failed: \(String(describing: error))")
        case .cancelled:
            if case .failed = state {} else { state = .stopped }
        default:
            break
        }
    }

    private static func describe(_ error: NWError) -> String {
        if case let .posix(code) = error, code == .EADDRINUSE {
            return "Port already in use — pick another in Settings."
        }
        return error.localizedDescription
    }

    // MARK: - Connections

    private func accept(_ connection: NWConnection) {
        let id = UUID()
        connections[id] = connection
        clients.append(
            BridgeClient(id: id, browserName: "Browser", isAuthenticated: false, connectedAt: Date())
        )

        connection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                switch state {
                case .ready:
                    self?.receive(on: id)
                case .cancelled, .failed:
                    self?.drop(id)
                default:
                    break
                }
            }
        }
        connection.start(queue: queue)

        // A client that never authenticates is dropped rather than left holding a socket.
        let timeout = authenticationTimeout
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(timeout))
            guard let self, self.connections[id] != nil, !self.authenticated.contains(id) else {
                return
            }
            self.send(.rejected(reason: "Pairing code required"), to: id) { [weak self] in
                self?.drop(id)
            }
        }
    }

    private func receive(on id: UUID) {
        guard let connection = connections[id] else { return }
        connection.receiveMessage { [weak self] data, context, _, error in
            Task { @MainActor in
                guard let self else { return }
                if let error {
                    self.log.debug("Bridge receive error: \(String(describing: error))")
                    self.drop(id)
                    return
                }

                if let metadata = context?.protocolMetadata(
                    definition: NWProtocolWebSocket.definition
                ) as? NWProtocolWebSocket.Metadata, metadata.opcode == .close {
                    self.drop(id)
                    return
                }

                if let data, !data.isEmpty { self.handle(data, from: id) }
                if self.connections[id] != nil { self.receive(on: id) }
            }
        }
    }

    private func drop(_ id: UUID) {
        guard let connection = connections.removeValue(forKey: id) else { return }
        // Send a real close frame before cancelling, so the extension sees a clean shutdown rather
        // than a socket error it has to guess about.
        if connection.state == .ready {
            let metadata = NWProtocolWebSocket.Metadata(opcode: .close)
            metadata.closeCode = .protocolCode(.normalClosure)
            let context = NWConnection.ContentContext(identifier: "close", metadata: [metadata])
            connection.send(
                content: nil, contentContext: context, isComplete: true,
                completion: .contentProcessed { _ in connection.cancel() }
            )
        } else {
            connection.cancel()
        }
        authenticated.remove(id)
        clients.removeAll { $0.id == id }
        onClientDisconnected?(id)
    }

    // MARK: - Messages

    private func handle(_ data: Data, from id: UUID) {
        guard let message = try? decoder.decode(BridgeInbound.self, from: data) else {
            log.debug("Ignoring malformed bridge message")
            return
        }

        switch message {
        case let .hello(token, browser, version):
            let expected = tokenProvider?() ?? ""
            guard version >= 1, Self.constantTimeEquals(token, expected) else {
                // Flush the reason before closing so the extension can explain what went wrong.
                send(.rejected(reason: "Pairing code does not match Audify"), to: id) { [weak self] in
                    self?.drop(id)
                }
                return
            }
            authenticated.insert(id)
            if let index = clients.firstIndex(where: { $0.id == id }) {
                clients[index].browserName = browser
                clients[index].isAuthenticated = true
            }
            if let welcome = welcomeProvider?() { send(welcome, to: id) }
            send(.requestTabs, to: id)
            log.info("Bridge paired with \(browser, privacy: .public)")

        case let .tabs(tabs):
            guard authenticated.contains(id) else { return }
            onTabs?(id, tabs)

        case .tabClosed:
            // The extension always reports whole tab lists, so just ask for a fresh one.
            guard authenticated.contains(id) else { return }
            send(.requestTabs, to: id)

        case .pong:
            break
        }
    }

    public func send(_ message: BridgeOutbound, to id: UUID, then completion: (() -> Void)? = nil) {
        guard let connection = connections[id], let data = try? encoder.encode(message) else {
            completion?()
            return
        }
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "audify", metadata: [metadata])
        connection.send(
            content: data, contentContext: context, isComplete: true,
            completion: .contentProcessed { _ in
                guard let completion else { return }
                Task { @MainActor in completion() }
            }
        )
    }

    public func broadcast(_ message: BridgeOutbound) {
        for id in authenticated { send(message, to: id) }
    }

    public var isConnected: Bool { !authenticated.isEmpty }

    /// Length-independent comparison so a wrong code cannot be narrowed down by timing.
    private static func constantTimeEquals(_ lhs: String, _ rhs: String) -> Bool {
        let a = Array(lhs.uppercased().utf8)
        let b = Array(rhs.uppercased().utf8)
        guard !b.isEmpty else { return false }
        var difference = UInt8(a.count == b.count ? 0 : 1)
        for index in 0..<max(a.count, b.count) {
            let left = index < a.count ? a[index] : 0
            let right = index < b.count ? b[index] : 0
            difference |= left ^ right
        }
        return difference == 0
    }
}
