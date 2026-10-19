import Foundation
import Combine

class NetworkManager: ObservableObject {
    private var task: URLSessionWebSocketTask?
    
    func connect(to ip: String) {
        let url = URL(string: "ws://\(ip):8765")!
        task = URLSession.shared.webSocketTask(with: url)
        task?.resume()
        
        // 1. Send Handshake
        let handshake = ["type": "handshake", "device": "iPhone"]
        let data = try! JSONSerialization.data(withJSONObject: handshake)
        let string = String(data: data, encoding: .utf8)!
        task?.send(.string(string)) { error in
            if let error = error { print("Handshake error: \(error)") }
        }
        
        // 2. Listen for commands
        receiveMessage()
    }
    
    private func receiveMessage() {
        task?.receive { [weak self] result in
            switch result {
            case .failure(let error):
                print("Error receiving: \(error)")
            case .success(let message):
                if case .string(let text) = message {
                    print("📱 Received command: \(text)")
                    // Mock taking a picture...
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        self?.sendMockReading()
                    }
                }
                self?.receiveMessage() // Loop to listen for more
            }
        }
    }
    
    private func sendMockReading() {
        // We match the patch_id from the server's command
        let reading = ["type": "reading", "patch_id": "test_red_01", "raw_data": [4095, 120, 95]]
        let data = try! JSONSerialization.data(withJSONObject: reading)
        let string = String(data: data, encoding: .utf8)!
        task?.send(.string(string)) { _ in }
    }
}
