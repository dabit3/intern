import Foundation

/// Thin HTTP client for the TypeSafe System One endpoint. Every call is one fan-out request.
struct JevClient: Sendable {
  struct Result: Sendable {
    let response: JevResponse
    let latencyMs: Double
  }

  enum Failure: Error, Equatable {
    case missingAPIKey
    case http(Int)
    case transport(String)
  }

  static let endpoint = URL(string: "https://api.typesafe.ai/v1/systemone")!
  static let apiKeyDefaultsKey = "typesafeAPIKey"
  static let requestTimeout: TimeInterval = 4

  /// `TYPESAFE_API_KEY` from the environment first, then the Settings field (UserDefaults).
  static func apiKey(environment: [String: String] = ProcessInfo.processInfo.environment)
    -> String?
  {
    if let key = environment["TYPESAFE_API_KEY"]?.trimmingCharacters(in: .whitespacesAndNewlines),
      !key.isEmpty
    {
      return key
    }
    if let key = UserDefaults.standard.string(forKey: apiKeyDefaultsKey)?.trimmingCharacters(
      in: .whitespacesAndNewlines), !key.isEmpty
    {
      return key
    }
    return nil
  }

  let session: URLSession

  init() {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = Self.requestTimeout
    configuration.httpMaximumConnectionsPerHost = 8
    configuration.httpShouldUsePipelining = true
    session = URLSession(configuration: configuration)
  }

  func ask(_ request: JevRequest) async throws -> Result {
    guard let key = Self.apiKey() else { throw Failure.missingAPIKey }
    var urlRequest = URLRequest(url: Self.endpoint)
    urlRequest.httpMethod = "POST"
    urlRequest.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
    urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
    urlRequest.httpBody = try JSONEncoder().encode(request)
    let started = DispatchTime.now()
    let (data, response): (Data, URLResponse)
    do {
      (data, response) = try await session.data(for: urlRequest)
    } catch {
      throw Failure.transport(error.localizedDescription)
    }
    let latencyMs = Double(DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1e6
    if let http = response as? HTTPURLResponse, http.statusCode != 200 {
      throw Failure.http(http.statusCode)
    }
    let decoded = try JSONDecoder().decode(JevResponse.self, from: data)
    return Result(response: decoded, latencyMs: latencyMs)
  }
}
