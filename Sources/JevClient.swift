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
    case rateLimited(TimeInterval)
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
  private let keyProvider: @Sendable () -> String?

  init(
    session: URLSession? = nil,
    apiKey: @escaping @Sendable () -> String? = { Self.apiKey() }
  ) {
    keyProvider = apiKey
    if let session {
      self.session = session
    } else {
      let configuration = URLSessionConfiguration.ephemeral
      configuration.timeoutIntervalForRequest = Self.requestTimeout
      configuration.timeoutIntervalForResource = Self.requestTimeout
      configuration.httpMaximumConnectionsPerHost = 8
      configuration.httpShouldUsePipelining = true
      configuration.httpShouldSetCookies = false
      configuration.urlCache = nil
      self.session = URLSession(configuration: configuration)
    }
  }

  func ask(_ request: JevRequest) async throws -> Result {
    try Task.checkCancellation()
    guard let key = keyProvider()?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty
    else { throw Failure.missingAPIKey }
    var urlRequest = URLRequest(
      url: Self.endpoint, cachePolicy: .reloadIgnoringLocalCacheData,
      timeoutInterval: Self.requestTimeout)
    urlRequest.httpMethod = "POST"
    urlRequest.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
    urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
    urlRequest.httpBody = try JSONEncoder().encode(request)
    let started = DispatchTime.now()
    let (data, response): (Data, URLResponse)
    do {
      (data, response) = try await session.data(for: urlRequest)
    } catch {
      if Task.isCancelled || (error as? URLError)?.code == .cancelled {
        throw CancellationError()
      }
      throw Failure.transport(error.localizedDescription)
    }
    try Task.checkCancellation()
    let latencyMs = Double(DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1e6
    guard let http = response as? HTTPURLResponse else {
      throw Failure.transport("Invalid HTTP response")
    }
    if http.statusCode != 200 {
      if http.statusCode == 429 || http.statusCode == 529 {
        throw Failure.rateLimited(Self.retryDelay(http.value(forHTTPHeaderField: "Retry-After")))
      }
      throw Failure.http(http.statusCode)
    }
    let decoded = try JSONDecoder().decode(JevResponse.self, from: data)
    return Result(response: decoded, latencyMs: latencyMs)
  }

  static func retryDelay(_ value: String?, now: Date = Date()) -> TimeInterval {
    guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines) else { return 15 }
    if let seconds = Double(value), seconds.isFinite { return min(3600, max(1, seconds)) }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
    guard let date = formatter.date(from: value) else { return 15 }
    let delay = date.timeIntervalSince(now)
    return delay.isFinite ? min(3600, max(1, delay)) : 15
  }
}
