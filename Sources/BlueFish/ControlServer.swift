import Foundation
import Network

/// Tiny localhost control server so DSH's sidebar button can ask the pet for
/// its state and toggle it even when the desktop host exposes no web routes.
final class PetControlServer {
    static let port: UInt16 = 47113

    private let queue = DispatchQueue(label: "com.daiwei.bluefish.control")
    private var listener: NWListener?
    var statusProvider: (() -> Bool)?          // panel.isVisible
    var actionHandler: ((String) -> Void)?     // toggle / show / hide / quit

    func start() {
        do {
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            parameters.requiredLocalEndpoint = .hostPort(
                host: "127.0.0.1",
                port: NWEndpoint.Port(rawValue: Self.port)!
            )
            let listener = try NWListener(using: parameters)
            listener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }
            listener.stateUpdateHandler = { state in
                if case let .failed(error) = state {
                    NSLog("bluefish control server failed: \(error)")
                }
            }
            listener.start(queue: queue)
            self.listener = listener
            NSLog("bluefish control server listening on 127.0.0.1:\(Self.port)")
        } catch {
            NSLog("bluefish control server start failed: \(error)")
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] data, _, _, _ in
            guard let self else { connection.cancel(); return }
            let text = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            let requestLine = text.split(separator: "\r\n").first.map(String.init) ?? ""
            let parts = requestLine.split(separator: " ")
            let method = parts.first.map { String($0).uppercased() } ?? "GET"
            let path = parts.count > 1
                ? String(String(parts[1]).split(separator: "?").first ?? "/")
                : "/"
            self.respond(connection, method: method, path: path)
        }
    }

    private func respond(_ connection: NWConnection, method: String, path: String) {
        let cors = [
            "Access-Control-Allow-Origin: *",
            "Access-Control-Allow-Methods: GET, POST, OPTIONS",
            "Access-Control-Allow-Headers: Content-Type"
        ].joined(separator: "\r\n") + "\r\n"

        if method == "OPTIONS" {
            send(connection, status: "204 No Content", body: "", cors: cors)
            return
        }

        switch (method, path) {
        case ("GET", "/status"):
            let visible = DispatchQueue.main.sync { self.statusProvider?() ?? false }
            send(connection, status: "200 OK",
                 body: "{\"ok\":true,\"running\":true,\"visible\":\(visible)}", cors: cors)
        case ("POST", "/toggle"), ("POST", "/show"), ("POST", "/hide"):
            let action = String(path.dropFirst())
            DispatchQueue.main.sync { self.actionHandler?(action) }
            let visible = DispatchQueue.main.sync { self.statusProvider?() ?? false }
            let status = "{\"ok\":true,\"running\":true,\"visible\":\(visible)}"
            send(connection, status: "200 OK", body: "{\"ok\":true,\"status\":\(status)}", cors: cors)
        case ("POST", "/axdump"):
            DispatchQueue.main.async { self.actionHandler?("axdump") }
            send(connection, status: "200 OK", body: "{\"ok\":true}", cors: cors)
        case ("POST", "/recenter"):
            DispatchQueue.main.sync { self.actionHandler?("recenter") }
            let visible = DispatchQueue.main.sync { self.statusProvider?() ?? false }
            send(connection, status: "200 OK",
                 body: "{\"ok\":true,\"status\":{\"ok\":true,\"running\":true,\"visible\":\(visible)}}", cors: cors)
        case ("POST", "/quit"):
            DispatchQueue.main.async { self.actionHandler?("quit") }
            send(connection, status: "200 OK", body: "{\"ok\":true}", cors: cors)
        default:
            send(connection, status: "404 Not Found", body: "{\"ok\":false}", cors: cors)
        }
    }

    private func send(_ connection: NWConnection, status: String, body: String, cors: String) {
        let bodyData = Data(body.utf8)
        let head = "HTTP/1.1 \(status)\r\nContent-Type: application/json; charset=utf-8\r\n\(cors)Content-Length: \(bodyData.count)\r\nConnection: close\r\n\r\n"
        var payload = Data(head.utf8)
        payload.append(bodyData)
        connection.send(content: payload, completion: .contentProcessed { _ in connection.cancel() })
    }
}
