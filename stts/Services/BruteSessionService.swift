import Foundation

struct SessionProject: Decodable, Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let folder: String?

    static func knowledgeBase(in projects: [SessionProject]) -> SessionProject? {
        projects.first { $0.id == "system-kb" }
            ?? projects.first {
                $0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "knowledge base"
            }
    }
}

struct SessionImage: Codable, Equatable, Sendable {
    let name: String
    let mediaType: String
    let dataBase64: String

    enum CodingKeys: String, CodingKey {
        case name
        case mediaType = "media_type"
        case dataBase64 = "data_base64"
    }

    init(pngData: Data) {
        name = "mac-display.png"
        mediaType = "image/png"
        dataBase64 = pngData.base64EncodedString()
    }
}

struct SessionCreationRequest: Encodable, Sendable {
    let agentID = "build"
    let task: String
    let projectID: String
    let images: [SessionImage]
    // Like adapter-chrome, serial queueing persists the initial message and schedules execution.
    let queued = true
    let queueMode = "serial"

    enum CodingKeys: String, CodingKey {
        case task, images, queued
        case agentID = "agent_id"
        case projectID = "project_id"
        case queueMode = "queue_mode"
    }

    init(task: String, projectID: String, images: [SessionImage]) throws {
        let task = task.trimmingCharacters(in: .whitespacesAndNewlines)
        let projectID = projectID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !task.isEmpty else { throw SessionServiceError.message("Enter a message before creating a session.") }
        guard !projectID.isEmpty else {
            throw SessionServiceError.message("Choose a project before creating a session.")
        }
        self.task = task
        self.projectID = projectID
        self.images = images
    }
}

struct CreatedSession: Decodable, Equatable, Sendable {
    let id: String
    let projectID: String?

    enum CodingKeys: String, CodingKey {
        case id
        case projectID = "project_id"
    }
}

enum SessionServiceError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self {
        case .message(let message): return message
        }
    }
}

struct BruteSessionService: Sendable {
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)
    private let transport: Transport

    init(
        transport: @escaping Transport = { request in
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let response = response as? HTTPURLResponse else {
                throw SessionServiceError.message("Brute returned a non-HTTP response.")
            }
            return (data, response)
        }
    ) {
        self.transport = transport
    }

    func listProjects(baseURL: URL) async throws -> [SessionProject] {
        let data = try await send(baseURL: baseURL, path: "projects")
        return try JSONDecoder().decode([SessionProject].self, from: data)
    }

    func knowledgeBaseProject(baseURL: URL) async throws -> SessionProject {
        let projects = try await listProjects(baseURL: baseURL)
        guard let project = SessionProject.knowledgeBase(in: projects) else {
            // Do not silently create an unbound session or a duplicate system project.
            throw SessionServiceError.message(
                "Knowledge Base was not found. Open Brute to restore it, or choose a project manually.")
        }
        return project
    }

    func create(baseURL: URL, request: SessionCreationRequest) async throws -> CreatedSession {
        let data = try await send(baseURL: baseURL, path: "sessions", body: JSONEncoder().encode(request))
        let session = try JSONDecoder().decode(CreatedSession.self, from: data)
        guard !session.id.isEmpty, session.projectID == request.projectID else {
            throw SessionServiceError.message(
                "Brute returned an incomplete session. Check Caesar before retrying to avoid a duplicate.")
        }
        return session
    }

    private func send(baseURL: URL, path: String, body: Data? = nil) async throws -> Data {
        guard ["http", "https"].contains(baseURL.scheme?.lowercased() ?? ""), baseURL.host != nil else {
            throw SessionServiceError.message("Configure a valid Brute HTTP URL in Audio & speech settings.")
        }
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.timeoutInterval = 30
        request.httpMethod = body == nil ? "GET" : "POST"
        request.httpBody = body
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let (data, response) = try await transport(request)
        guard (200...299).contains(response.statusCode) else {
            throw SessionServiceError.message(
                WhisperService.extractErrorMessage(from: data)
                    ?? "Brute returned HTTP \(response.statusCode).")
        }
        return data
    }

    static func caesarURL(sessionID: String) -> URL? {
        var components = URLComponents(string: "https://my.a2gent.net/")
        components?.fragment = "/chat/\(sessionID)"
        return components?.url
    }
}
