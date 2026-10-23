import Foundation

public enum OllamaModelUnloadRequest {
    public static func make(serverURL: String, modelName: String) -> URLRequest? {
        let base = serverURL
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/+$", with: "", options: .regularExpression)
        guard let url = URL(string: base + "/api/generate") else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "model": modelName,
            "keep_alive": 0
        ])
        return request
    }
}
