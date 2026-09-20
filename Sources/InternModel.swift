import AppKit
import Combine
import Foundation

@MainActor
final class InternModel: ObservableObject {
  static let readyThreshold = 0.6
  static let certainTargetThreshold = 0.9
  static let certainSetThreshold = 0.75
  static let missingAPIKeyMessage = "Add a TypeSafe key in Settings. Local search is available."
  static let cooldownMessage =
    "Online ranking is busy. Using local search until the cooldown ends."
  static let oversizedQueryMessage =
    "Query is too long for online ranking. Local results are available."

  @Published var query = "" {
    didSet { if query != oldValue { queryChanged() } }
  }
  @Published var scope: SearchScope = .all {
    didSet { if scope != oldValue { queryChanged() } }
  }
  @Published private(set) var hits: [RankedHit] = []
  @Published var selection = 0
  @Published private(set) var judgment: JevJudgment?
  @Published private(set) var judgmentIsFresh = false
  @Published private(set) var stats = LatencyStats()
  @Published private(set) var inFlight = 0
  @Published private(set) var lastError: String?
  @Published private(set) var status: String?
  @Published private(set) var indexSize = 0
  @Published private(set) var isIndexing = false
  @Published var actionsVisible = false {
    didSet {
      if actionsVisible {
        actionSelection = 0
        manuallySelectedID = topHit?.id
      }
    }
  }
  @Published private(set) var actionSelection = 0
  @Published var workspaceName = ""
  @Published var savingWorkspace = false
  @Published private(set) var confirmation: Candidate?
  @Published private(set) var isExecuting = false
  @Published private(set) var settingsRequests = 0

  let library: PersonalLibrary
  var onExecute: (() -> Void)?
  var onExecutionFailure: (() -> Void)?
  var onPreview: ((URL) -> Void)?
  var onOpenSettings: ((_ open: () -> Void) -> Void)?

  var needsAPIKey: Bool { lastError == Self.missingAPIKeyMessage }

  /// Typing pauses this long before a keystroke asks Jev or Spotlight; local results never wait.
  var judgmentDelay: Duration = .milliseconds(150)
  var spotlightDelay: Duration = .milliseconds(60)

  private let defaults: UserDefaults
  private var index: [Candidate] = [] {
    didSet { mergedEntries = nil }
  }
  private var spotlightCandidates: [Candidate] = [] {
    didSet { mergedEntries = nil }
  }
  private var recentCandidates: [Candidate] = [] {
    didSet { mergedEntries = nil }
  }
  private var recentsRefreshed = Date.distantPast
  static let recentsInterval: TimeInterval = 30
  private var libraryCandidates: [Candidate] = [] {
    didSet { mergedEntries = nil }
  }
  private var mergedEntries: [Ranker.Entry]?
  private var documents: [DocumentKey: Fuzzy.Document] = [:]
  /// The effective query the current Spotlight results were for.
  private var spotlightQuery = ""
  private var prefiltered = Ranker.Prefiltered(candidates: [], fuzzy: [:])
  /// The effective query the current judgment answered, so refinements can keep it as stale.
  private var judgedQuery = ""
  private var lastRequest: RequestSignature?
  private var judgmentTask: Task<Void, Never>?
  private var spotlightTask: Task<Void, Never>?
  private var sequence = 0
  private var queryGeneration = 0
  private var indexGeneration = 0
  private var executionGeneration = 0
  private var manuallySelectedID: String?
  private var memberSelection: Set<String>?
  private var selectedMemberCandidates: [String: Candidate] = [:]
  private var reviewedGroup: [Candidate]?
  private var retryAfter = Date.distantPast
  private var backoff: TimeInterval = 0
  private var isShowing = false
  private var context = LaunchContext(
    frontmostApp: "", recentApps: [], clipboardKind: "empty", timeOfDay: "", weekday: "")
  private let ask: @Sendable (JevRequest) async throws -> JevClient.Result
  private let execute: @MainActor (Candidate) async -> Executor.Outcome
  private let buildIndex: @Sendable (Bool) async -> LocalIndex
  private let indexStore: IndexStore?
  private let spotlight = SpotlightSearch()
  private let recents = SpotlightSearch()
  private var indexTask: Task<Void, Never>?
  private var requestTask: Task<Void, Never>?
  private var subscriptions = Set<AnyCancellable>()

  init(
    defaults: UserDefaults = .standard,
    execute: (@MainActor (Candidate) async -> Executor.Outcome)? = nil,
    buildIndex: (@Sendable (Bool) async -> LocalIndex)? = nil,
    indexStore: IndexStore? = nil,
    ask: (@Sendable (JevRequest) async throws -> JevClient.Result)? = nil
  ) {
    self.defaults = defaults
    library = PersonalLibrary(defaults: defaults)
    let client = JevClient()
    self.ask = ask ?? { try await client.ask($0) }
    self.execute = execute ?? { await Executor.perform($0) }
    self.buildIndex = buildIndex ?? { await LocalIndexScanner.shared.build(includeHistory: $0) }
    self.indexStore = indexStore
    if let indexStore {
      Task.detached(priority: .utility) { [weak self] in
        guard let stored = indexStore.load() else { return }
        await MainActor.run { [weak self] in
          guard let self, self.index.isEmpty else { return }
          self.replaceIndex(stored)
        }
      }
    }
    NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
      .receive(on: DispatchQueue.main)
      .sink { [weak self] _ in
        guard let self, self.isShowing else { return }
        self.preferencesChanged()
      }
      .store(in: &subscriptions)
    currentPreferences = preferences
    libraryCandidates = visibleLibraryCandidates()
  }

  deinit {
    indexTask?.cancel()
    requestTask?.cancel()
    judgmentTask?.cancel()
    spotlightTask?.cancel()
  }

  private struct RequestSignature: Equatable {
    let query: String
    let candidateIDs: [String]
  }

  /// Tokenized text depends only on these, so a rebuilt index reuses documents for unchanged items.
  private struct DocumentKey: Hashable {
    let id: String
    let title: String
    let keywords: [String]

    init(_ candidate: Candidate) {
      id = candidate.id
      title = candidate.title
      keywords = candidate.keywords
    }
  }

  private var effectiveQuery: String {
    query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
  }

  /// A judgment still says something useful while the same request is being typed further
  /// (or backspaced), so it stays visible as stale instead of the list snapping to local order.
  static func isRefinement(_ judged: String, _ current: String) -> Bool {
    guard !judged.isEmpty, !current.isEmpty else { return false }
    return current.hasPrefix(judged) || judged.hasPrefix(current)
  }

  private struct Preferences: Equatable {
    let history: Bool
    let spotlight: Bool
    let localOnly: Bool
    let apiKey: String
  }

  private var preferences: Preferences {
    Preferences(
      history: defaults.object(forKey: "includeChromeHistory") as? Bool ?? true,
      spotlight: defaults.object(forKey: "includeSpotlight") as? Bool ?? true,
      localOnly: defaults.bool(forKey: "localOnly"),
      apiKey: defaults.string(forKey: JevClient.apiKeyDefaultsKey)?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
  }

  private var currentPreferences = Preferences(
    history: true, spotlight: true, localOnly: false, apiKey: "")
  var isLocalOnly: Bool { preferences.localOnly }
  var isEmptyQuery: Bool { query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
  var hasAPIKey: Bool {
    ProcessInfo.processInfo.environment["TYPESAFE_API_KEY"]?
      .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
      || !preferences.apiKey.isEmpty
  }
  var topHit: RankedHit? { hits.indices.contains(selection) ? hits[selection] : hits.first }
  var hasEditableGroup: Bool { memberSelection != nil || hits.contains { $0.id == Ranker.groupID } }

  var selectedMembers: [Candidate] {
    if case .group(let members) = topHit?.candidate.payload { return members }
    if let group = hits.first(where: { $0.id == Ranker.groupID }),
      case .group(let members) = group.candidate.payload
    {
      return members
    }
    return []
  }

  var availableActions: [InternAction] {
    guard let candidate = topHit?.candidate else { return [] }
    var actions: [InternAction] = [.open]
    if case .file = candidate.payload { actions.append(.preview) }
    if candidate.fileURL != nil { actions.append(.reveal) }
    if Executor.copyText(candidate) != nil { actions.append(.copy) }
    if candidate.isOpenable || candidate.id.hasPrefix("workspace:") { actions.append(.pin) }
    if candidate.isOpenable { actions.append(.member) }
    if case .group = candidate.payload { actions.append(.reviewGroup) }
    if selectedMembers.count >= 2 { actions.append(.saveWorkspace) }
    if candidate.id.hasPrefix("workspace:") { actions.append(.deleteWorkspace) }
    return actions
  }

  func moveActionSelection(by delta: Int) {
    actionSelection = min(max(0, actionSelection + delta), max(0, availableActions.count - 1))
  }

  func performSelectedAction() {
    guard availableActions.indices.contains(actionSelection) else { return }
    performAction(availableActions[actionSelection])
  }

  func performAction(_ action: InternAction) {
    switch action {
    case .open: executeSelection()
    case .preview: previewSelection()
    case .reveal: revealSelection()
    case .copy: copySelection()
    case .pin: togglePin()
    case .member:
      if let candidate = topHit?.candidate { toggleMember(candidate) }
      actionsVisible = false
    case .reviewGroup: reviewGroup()
    case .saveWorkspace:
      workspaceName = ""
      savingWorkspace = true
    case .deleteWorkspace: deleteWorkspace()
    }
  }

  var isReady: Bool {
    guard let judgment, judgmentIsFresh, selection == 0, let top = hits.first,
      !isExecuting, confirmation == nil, judgment.noneProbability < 0.5
    else { return false }
    if top.id == Ranker.groupID {
      return memberSelection == nil && judgment.setProbability >= Self.certainSetThreshold
    }
    let jevTop = judgment.targetProbabilities.max { $0.value < $1.value }?.key
    return (judgment.ready >= Self.readyThreshold && jevTop == top.id)
      || (top.jevProbability ?? 0) >= Self.certainTargetThreshold
  }

  func panelWillShow() {
    isShowing = true
    if currentPreferences != preferences {
      if currentPreferences.apiKey != preferences.apiKey {
        retryAfter = .distantPast
        backoff = 0
      }
      currentPreferences = preferences
      index = []
      spotlightCandidates = []
    }
    captureContext()
    status = nil
    libraryCandidates = visibleLibraryCandidates()
    refreshResults()
    rebuildIndex()
    refreshRecents()
  }

  private func refreshRecents() {
    guard preferences.spotlight else {
      if !recentCandidates.isEmpty { recentCandidates = [] }
      return
    }
    guard Date().timeIntervalSince(recentsRefreshed) >= Self.recentsInterval else { return }
    recentsRefreshed = Date()
    recents.recentlyUsed { [weak self] candidates in
      guard let self, candidates != self.recentCandidates else { return }
      self.recentCandidates = candidates
      self.refreshResults()
      if !self.isEmptyQuery { self.requestJudgment() }
    }
  }

  func rebuildIndex() {
    indexGeneration += 1
    let generation = indexGeneration
    indexTask?.cancel()
    isIndexing = true
    let includeHistory = preferences.history
    let buildIndex = buildIndex
    let indexStore = indexStore
    indexTask = Task(priority: .userInitiated) { [weak self] in
      let built = await buildIndex(includeHistory)
      guard let self, !Task.isCancelled, generation == self.indexGeneration else { return }
      self.isIndexing = false
      let changed = built.candidates != self.index
      self.replaceIndex(built.candidates)
      if let indexStore, changed, !built.candidates.isEmpty {
        let candidates = built.candidates
        Task.detached(priority: .utility) { indexStore.save(candidates) }
      }
    }
  }

  func replaceIndex(_ candidates: [Candidate]) {
    guard candidates != index else { return }
    index = candidates
    indexSize = candidates.count
    refreshResults()
    if !isEmptyQuery { requestJudgment() }
  }

  func openSettings(_ open: () -> Void) {
    if let onOpenSettings { onOpenSettings(open) } else { open() }
  }

  func requestSettings() {
    settingsRequests += 1
  }

  func preferencesChanged() {
    guard currentPreferences != preferences else { return }
    let historyChanged = currentPreferences.history != preferences.history
    let apiKeyChanged = currentPreferences.apiKey != preferences.apiKey
    if historyChanged {
      index = []
      indexGeneration += 1
      indexTask?.cancel()
      isIndexing = false
    }
    if apiKeyChanged {
      retryAfter = .distantPast
      backoff = 0
    }
    currentPreferences = preferences
    libraryCandidates = visibleLibraryCandidates()
    queryChanged()
    if isShowing && historyChanged { rebuildIndex() }
  }

  func reset() {
    isShowing = false
    executionGeneration += 1
    isExecuting = false
    indexGeneration += 1
    indexTask?.cancel()
    isIndexing = false
    query = ""
    queryGeneration += 1
    cancelRequests()
    hits = []
    selection = 0
    judgment = nil
    judgmentIsFresh = false
    judgedQuery = ""
    lastRequest = nil
    confirmation = nil
    reviewedGroup = nil
    memberSelection = nil
    selectedMemberCandidates = [:]
    manuallySelectedID = nil
    actionsVisible = false
    savingWorkspace = false
    workspaceName = ""
    status = nil
    lastError = nil
  }

  func moveSelection(by delta: Int) {
    guard !hits.isEmpty else { return }
    select(min(max(selection + delta, 0), hits.count - 1))
  }

  func select(_ index: Int) {
    guard hits.indices.contains(index) else { return }
    selection = index
    manuallySelectedID = hits[index].id
    confirmation = nil
  }

  func cycleScope(backward: Bool = false) {
    let scopes = SearchScope.allCases
    let index = scopes.firstIndex(of: scope) ?? 0
    scope = scopes[(index + (backward ? scopes.count - 1 : 1)) % scopes.count]
  }

  func toggleMember(_ candidate: Candidate) {
    guard candidate.isOpenable else { return }
    if memberSelection == nil {
      selectedMemberCandidates = Dictionary(
        uniqueKeysWithValues: hits.filter(\.inSet).map { ($0.id, $0.candidate) })
    }
    var members = memberSelection ?? Set(hits.filter(\.inSet).map(\.id))
    if members.contains(candidate.id) {
      members.remove(candidate.id)
      selectedMemberCandidates.removeValue(forKey: candidate.id)
    } else if members.count < Ranker.maximumSetSize {
      members.insert(candidate.id)
      selectedMemberCandidates[candidate.id] = candidate
    }
    memberSelection = members
    confirmation = nil
    updateHits()
  }

  func reviewGroup() {
    guard case .group(let members) = topHit?.candidate.payload else { return }
    sequence += 1
    requestTask?.cancel()
    inFlight = 0
    judgment = nil
    judgmentIsFresh = false
    reviewedGroup = members
    memberSelection = Set(members.map(\.id))
    selectedMemberCandidates = Dictionary(uniqueKeysWithValues: members.map { ($0.id, $0) })
    manuallySelectedID = Ranker.groupID
    actionsVisible = false
    refreshResults()
  }

  func togglePin() {
    guard let candidate = topHit?.candidate else { return }
    library.togglePin(candidate)
    libraryCandidates = visibleLibraryCandidates()
    actionsVisible = false
    refreshResults()
    if !isEmptyQuery { requestJudgment() }
  }

  func saveWorkspace() {
    guard library.saveWorkspace(name: workspaceName, members: selectedMembers) else {
      status = "Use a name and 2–25 items. Up to 20 workspaces can be saved."
      return
    }
    savingWorkspace = false
    actionsVisible = false
    workspaceName = ""
    status = "Workspace saved"
    libraryCandidates = visibleLibraryCandidates()
    refreshResults()
    if !isEmptyQuery { requestJudgment() }
  }

  func deleteWorkspace() {
    guard let candidate = topHit?.candidate, candidate.id.hasPrefix("workspace:") else { return }
    library.deleteWorkspace(id: candidate.id)
    index.removeAll { $0.id == candidate.id }
    spotlightCandidates.removeAll { $0.id == candidate.id }
    libraryCandidates = visibleLibraryCandidates()
    actionsVisible = false
    refreshResults()
    if !isEmptyQuery { requestJudgment() }
  }

  func clearHistory() {
    library.clearHistory()
    libraryCandidates = visibleLibraryCandidates()
    refreshResults()
    if !isEmptyQuery { requestJudgment() }
  }

  func revealSelection() {
    guard let candidate = topHit?.candidate, let url = candidate.fileURL else { return }
    guard validate(candidate) else { return }
    NSWorkspace.shared.activateFileViewerSelecting([url])
    onExecute?()
  }

  func previewSelection() {
    guard let candidate = topHit?.candidate, case .file(let url) = candidate.payload else { return }
    actionsVisible = false
    onPreview?(url)
  }

  func copySelection() {
    guard let candidate = topHit?.candidate, let text = Executor.copyText(candidate) else { return }
    NSPasteboard.general.clearContents()
    actionsVisible = false
    guard NSPasteboard.general.setString(text, forType: .string) else {
      status = nil
      lastError = "Couldn't write to the clipboard. Try again."
      return
    }
    lastError = nil
    status = "Copied"
  }

  func cancelOverlay() -> Bool {
    if confirmation != nil {
      confirmation = nil
      return true
    }
    if savingWorkspace {
      savingWorkspace = false
      return true
    }
    if actionsVisible {
      actionsVisible = false
      return true
    }
    return false
  }

  func executeSelection() {
    guard !isExecuting, let hit = topHit else { return }
    let candidate = confirmation ?? hit.candidate
    if case .toggle(.emptyTrash) = candidate.payload, confirmation?.id != candidate.id {
      confirmation = candidate
      manuallySelectedID = candidate.id
      return
    }
    confirmation = nil
    let executedQuery = query
    let queryAtExecution = queryGeneration
    executionGeneration += 1
    let execution = executionGeneration
    let execute = execute
    isExecuting = true
    Task { [weak self] in
      let result = await execute(candidate)
      guard let self else { return }
      if execution == self.executionGeneration {
        self.isExecuting = false
      }
      if result.succeeded {
        self.library.record(candidate, query: executedQuery)
        self.libraryCandidates = self.visibleLibraryCandidates()
      }
      guard execution == self.executionGeneration, queryAtExecution == self.queryGeneration else {
        return
      }
      self.status = result.succeeded ? result.message : nil
      if result.succeeded {
        self.lastError = nil
        self.onExecute?()
      } else {
        self.lastError = result.message
        self.sequence += 1
        self.requestTask?.cancel()
        self.inFlight = 0
        self.judgment = nil
        self.judgmentIsFresh = false
        if let url = candidate.fileURL, url.isFileURL,
          !FileManager.default.fileExists(atPath: url.path)
        {
          self.index.removeAll { $0.id == candidate.id }
          self.spotlightCandidates.removeAll { $0.id == candidate.id }
          self.recentCandidates.removeAll { $0.id == candidate.id }
          self.libraryCandidates.removeAll { $0.id == candidate.id }
          self.memberSelection?.remove(candidate.id)
          self.selectedMemberCandidates.removeValue(forKey: candidate.id)
          self.reviewedGroup?.removeAll { $0.id == candidate.id }
        }
        self.refreshResults()
        self.onExecutionFailure?()
      }
    }
  }

  private func captureContext() {
    let workspace = NSWorkspace.shared
    let recent = workspace.runningApplications
      .filter {
        $0.activationPolicy == .regular && $0.bundleIdentifier != Bundle.main.bundleIdentifier
      }
      .compactMap(\.localizedName).prefix(8)
    let hour = Calendar.current.component(.hour, from: Date())
    context = LaunchContext(
      frontmostApp: workspace.frontmostApplication?.localizedName ?? "Finder",
      recentApps: Array(recent), clipboardKind: clipboardKind(),
      timeOfDay: LaunchContext.timeOfDay(hour: hour),
      weekday: Calendar.current.weekdaySymbols[
        Calendar.current.component(.weekday, from: Date()) - 1])
  }

  private func clipboardKind() -> String {
    let types = NSPasteboard.general.types ?? []
    if types.contains(.fileURL) { return "file" }
    if types.contains(.URL) { return "url" }
    if types.contains(.png) || types.contains(.tiff) { return "image" }
    if types.contains(.string) { return "text" }
    return types.isEmpty ? "empty" : "other"
  }

  private func queryChanged() {
    queryGeneration += 1
    let generation = queryGeneration
    manuallySelectedID = nil
    memberSelection = nil
    selectedMemberCandidates = [:]
    reviewedGroup = nil
    confirmation = nil
    actionsVisible = false
    savingWorkspace = false
    status = nil
    lastError = nil
    selection = 0
    cancelRequests()
    let refining = Self.isRefinement(judgedQuery, effectiveQuery)
    if judgment != nil, refining {
      judgmentIsFresh = false
    } else {
      judgment = nil
      judgmentIsFresh = false
    }
    if !spotlightCandidates.isEmpty,
      isEmptyQuery || !Self.isRefinement(spotlightQuery, effectiveQuery)
    {
      spotlightCandidates = []
    }
    refreshResults()
    guard !isEmptyQuery else { return }
    if !isLocalOnly {
      if query.utf8.count > JevQuestions.maxQueryBytes {
        lastError = Self.oversizedQueryMessage
      } else if Date() < retryAfter {
        lastError = Self.cooldownMessage
      }
    }
    judgmentTask = Task { [weak self, judgmentDelay] in
      try? await Task.sleep(for: judgmentDelay)
      guard let self, !Task.isCancelled, generation == self.queryGeneration else { return }
      self.requestJudgment()
    }
    if preferences.spotlight, scope == .all || scope == .files {
      spotlightTask = Task { [weak self, spotlightDelay] in
        try? await Task.sleep(for: spotlightDelay)
        guard let self, !Task.isCancelled, generation == self.queryGeneration else { return }
        self.spotlight.search(self.query) { [weak self] candidates in
          guard let self, generation == self.queryGeneration else { return }
          self.spotlightQuery = self.effectiveQuery
          if candidates != self.spotlightCandidates { self.spotlightCandidates = candidates }
          self.refreshResults()
          self.requestJudgment()
        }
      }
    }
  }

  private func cancelRequests() {
    judgmentTask?.cancel()
    judgmentTask = nil
    spotlightTask?.cancel()
    spotlightTask = nil
    spotlight.stop()
    sequence += 1
    requestTask?.cancel()
    requestTask = nil
    inFlight = 0
  }

  private func mergedCandidates() -> [Ranker.Entry] {
    if let mergedEntries { return mergedEntries }
    var candidates: [String: Candidate] = [:]
    for item in libraryCandidates + index + recentCandidates + spotlightCandidates {
      if case .file = item.payload, let opened = library.snapshot.records[item.id]?.lastOpened,
        opened > (item.lastOpenedAt ?? .distantPast)
      {
        candidates[item.id] = Candidate(
          id: item.id, title: item.title,
          subtitle:
            item.subtitle + " · "
            + LocalIndex.recency(max(0, Date().timeIntervalSince(opened)) / 86_400)
            .replacingOccurrences(of: "modified", with: "opened in launcher"),
          kind: item.kind, keywords: item.keywords, payload: item.payload, ageDays: item.ageDays,
          modifiedAt: item.modifiedAt, lastOpenedAt: opened, addedAt: item.addedAt)
      } else {
        candidates[item.id] = item
      }
    }
    let all = candidates.values.map { candidate in
      guard case .group(let members) = candidate.payload else { return candidate }
      return Candidate(
        id: candidate.id, title: candidate.title, subtitle: candidate.subtitle,
        kind: candidate.kind, keywords: candidate.keywords,
        payload: .group(members.map { candidates[$0.id] ?? $0 }))
    }.sorted { $0.id < $1.id }
    var retained: [DocumentKey: Fuzzy.Document] = [:]
    retained.reserveCapacity(all.count)
    let entries = all.map { candidate in
      let key = DocumentKey(candidate)
      let document = documents[key] ?? Fuzzy.Document(candidate)
      retained[key] = document
      return Ranker.Entry(candidate: candidate, document: document)
    }
    documents = retained
    mergedEntries = entries
    return entries
  }

  private func refreshResults() {
    if let reviewedGroup {
      prefiltered = Ranker.Prefiltered(
        candidates: reviewedGroup,
        fuzzy: Dictionary(uniqueKeysWithValues: reviewedGroup.map { ($0.id, 1) }))
      updateHits()
      return
    }
    let entries = mergedCandidates()
    if isEmptyQuery {
      hits = library.home(candidates: entries.map(\.candidate), scope: scope)
      selection =
        manuallySelectedID.flatMap { id in hits.firstIndex { $0.id == id } }
        ?? min(selection, max(0, hits.count - 1))
      return
    }
    prefiltered = Ranker.prefilter(
      query: query, entries: entries, scope: scope, boosts: library.boosts(query: query))
    updateHits()
  }

  private func updateHits() {
    var ranked = Ranker.rank(prefiltered, judgment: judgment, fresh: judgmentIsFresh)
    if let memberSelection {
      ranked.removeAll { $0.id == Ranker.groupID }
      let visible = Set(ranked.map(\.id))
      for candidate in selectedMemberCandidates.values.sorted(by: { $0.id < $1.id })
      where !visible.contains(candidate.id) {
        ranked.append(
          RankedHit(
            candidate: candidate, fuzzy: 0, jevProbability: nil,
            matchProbability: nil, inSet: true, score: 0))
      }
      ranked = ranked.map {
        RankedHit(
          candidate: $0.candidate, fuzzy: $0.fuzzy, jevProbability: $0.jevProbability,
          matchProbability: $0.matchProbability, inSet: memberSelection.contains($0.id),
          score: $0.score)
      }
      let members = ranked.filter(\.inSet).map(\.candidate)
      if !members.isEmpty {
        ranked.insert(
          RankedHit(
            candidate: Ranker.groupCandidate(members), fuzzy: 0, jevProbability: nil,
            matchProbability: nil, inSet: false, score: 1), at: 0)
      }
    }
    hits = ranked
    selection = manuallySelectedID.flatMap { id in hits.firstIndex { $0.id == id } } ?? 0
  }

  private func requestJudgment() {
    judgmentTask?.cancel()
    judgmentTask = nil
    let signature = RequestSignature(
      query: effectiveQuery, candidateIDs: prefiltered.candidates.map(\.id))
    if !isEmptyQuery, reviewedGroup == nil, judgment != nil, judgedQuery == signature.query,
      lastRequest == signature
    {
      // The same question is already answered; typing a trailing space changes nothing.
      if !judgmentIsFresh {
        judgmentIsFresh = true
        updateHits()
      }
      return
    }
    if inFlight > 0, lastRequest == signature { return }
    sequence += 1
    let seq = sequence
    requestTask?.cancel()
    inFlight = 0
    guard !isEmptyQuery, reviewedGroup == nil, !prefiltered.candidates.isEmpty, !isLocalOnly,
      Date() >= retryAfter
    else {
      if !isEmptyQuery, !isLocalOnly, Date() < retryAfter { lastError = Self.cooldownMessage }
      return
    }
    guard query.utf8.count <= JevQuestions.maxQueryBytes else {
      lastError = Self.oversizedQueryMessage
      return
    }
    let request = JevQuestions.buildRequest(
      query: query, context: context, candidates: prefiltered.candidates, window: prefiltered.window
    )
    let sent = prefiltered
    lastRequest = signature
    inFlight = 1
    if judgment != nil, judgmentIsFresh {
      judgmentIsFresh = false
      updateHits()
    }
    requestTask = Task { [weak self, ask] in
      guard !Task.isCancelled else { return }
      guard self?.isLocalOnly == false else {
        if self?.sequence == seq { self?.inFlight = 0 }
        return
      }
      do {
        let result = try await ask(request)
        guard let self else { return }
        guard seq == self.sequence, !Task.isCancelled else {
          self.stats.recordStale()
          return
        }
        self.inFlight = 0
        self.stats.recordSuccess(
          latencyMs: result.latencyMs, inputTokens: result.response.usage.inputTokens,
          outputTokens: result.response.usage.outputTokens, at: Date().timeIntervalSince1970)
        guard let parsed = JevQuestions.parse(result.response, candidates: sent.candidates) else {
          self.judgment = nil
          self.judgmentIsFresh = false
          self.lastError = "No usable online ranking returned. Local results are available."
          self.updateHits()
          return
        }
        self.judgment = parsed
        self.judgedQuery = signature.query
        self.backoff = 0
        self.judgmentIsFresh = true
        self.lastError = nil
        self.updateHits()
      } catch {
        guard let self, seq == self.sequence, !Task.isCancelled else { return }
        self.inFlight = 0
        self.stats.recordFailure()
        self.judgmentIsFresh = false
        if case JevClient.Failure.rateLimited(let delay) = error {
          self.backoff = max(delay, min(60, max(15, self.backoff * 2)))
          self.retryAfter = Date().addingTimeInterval(self.backoff)
        }
        self.lastError = self.describe(error)
        self.updateHits()
      }
    }
  }

  private func visibleLibraryCandidates() -> [Candidate] {
    library.candidates().filter { candidate in
      preferences.history || candidate.kind != .openURL || library.isPinned(candidate)
    }
  }

  private func validate(_ candidate: Candidate) -> Bool {
    guard let problem = Executor.validationError(candidate) else { return true }
    actionsVisible = false
    lastError = problem
    return false
  }

  private func describe(_ error: Error) -> String {
    if let failure = error as? JevClient.Failure {
      switch failure {
      case .missingAPIKey: return Self.missingAPIKeyMessage
      case .rateLimited: return Self.cooldownMessage
      case .http(let code): return "Ranking service returned HTTP \(code). Using local search."
      case .transport: return "Online ranking is unavailable. Using local search."
      }
    }
    return error.localizedDescription
  }
}
