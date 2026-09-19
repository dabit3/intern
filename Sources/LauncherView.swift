import AppKit
import SwiftUI

enum Theme {
  static let background = Color(red: 0.07, green: 0.075, blue: 0.09)
  static let surface = Color.white.opacity(0.07)
  static let border = Color.white.opacity(0.10)
  static let text = Color(red: 0.94, green: 0.945, blue: 0.96)
  static let dim = Color(red: 0.56, green: 0.58, blue: 0.64)
  static let faint = Color(red: 0.38, green: 0.40, blue: 0.46)
  static let accent = Color(red: 0.42, green: 0.78, blue: 1.0)
  static let ready = Color(red: 0.45, green: 0.92, blue: 0.58)
  static let warn = Color(red: 1.0, green: 0.72, blue: 0.36)
  static let danger = Color(red: 1.0, green: 0.46, blue: 0.46)
}

struct LauncherView: View {
  @ObservedObject var model: LauncherModel
  @FocusState private var focused: Bool

  private var isEmptyQuery: Bool { model.query.trimmingCharacters(in: .whitespaces).isEmpty }

  var body: some View {
    VStack(spacing: 0) {
      header
        .frame(height: LauncherPanelController.headerHeight)
      Divider().overlay(Theme.border)
      content
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      Divider().overlay(Theme.border)
      StatsFooter(model: model)
        .frame(height: LauncherPanelController.footerHeight)
    }
    .frame(width: LauncherPanelController.panelWidth)
    .frame(maxHeight: .infinity)
    .background {
      ZStack {
        Blur()
        Theme.background.opacity(0.86)
      }
    }
    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 18, style: .continuous)
        .strokeBorder(Theme.border, lineWidth: 1)
    )
    .preferredColorScheme(.dark)
    .onAppear { focused = true }
  }

  private var header: some View {
    HStack(spacing: 14) {
      Image(systemName: "bolt.fill")
        .font(.system(size: 20, weight: .medium))
        .foregroundStyle(model.isReady ? Theme.ready : Theme.faint)
        .animation(.easeOut(duration: 0.15), value: model.isReady)
      TextField("Say what you mean…", text: $model.query)
        .textFieldStyle(.plain)
        .font(.system(size: 24, weight: .regular, design: .rounded))
        .foregroundStyle(Theme.text)
        .focused($focused)
      Circle()
        .fill(Theme.accent)
        .frame(width: 6, height: 6)
        .opacity(model.inFlight > 0 ? 1 : 0)
        .animation(.easeOut(duration: 0.12), value: model.inFlight > 0)
        .accessibilityHidden(true)
    }
    .padding(.horizontal, 22)
  }

  @ViewBuilder
  private var content: some View {
    if isEmptyQuery {
      EmptyHint(model: model)
    } else if model.hits.isEmpty {
      Text("Nothing here matches yet")
        .font(.system(size: 14))
        .foregroundStyle(Theme.faint)
    } else {
      ScrollViewReader { proxy in
        ScrollView(showsIndicators: false) {
          LazyVStack(spacing: 0) {
            ForEach(Array(model.hits.enumerated()), id: \.element.id) { index, hit in
              HitRow(
                hit: hit, selected: index == model.selection,
                ready: model.isReady && index == 0,
                stale: !model.judgmentIsFresh && hit.jevProbability != nil
              )
              .frame(height: LauncherPanelController.rowHeight)
              .id(hit.id)
              .onTapGesture {
                model.selection = index
                model.executeSelection()
              }
            }
          }
          .padding(.horizontal, 8)
          .padding(.vertical, 6)
        }
        .onChange(of: model.selection) { _, selection in
          if model.hits.indices.contains(selection) {
            proxy.scrollTo(model.hits[selection].id)
          }
        }
      }
    }
  }
}

/// Native window blur behind the panel so it reads as part of the desktop, like Spotlight.
struct Blur: NSViewRepresentable {
  func makeNSView(context: Context) -> NSVisualEffectView {
    let view = NSVisualEffectView()
    view.material = .hudWindow
    view.blendingMode = .behindWindow
    view.state = .active
    return view
  }

  func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

struct HitRow: View {
  let hit: RankedHit
  let selected: Bool
  let ready: Bool
  let stale: Bool

  var body: some View {
    HStack(spacing: 14) {
      CandidateIcon(candidate: hit.candidate)
      VStack(alignment: .leading, spacing: 2) {
        Text(hit.candidate.title)
          .font(.system(size: 15, weight: .medium, design: .rounded))
          .foregroundStyle(Theme.text)
          .lineLimit(1)
        Text(hit.candidate.subtitle)
          .font(.system(size: 12))
          .foregroundStyle(Theme.dim)
          .lineLimit(1)
      }
      Spacer(minLength: 12)
      if hit.inSet {
        Image(systemName: "checkmark.circle.fill")
          .font(.system(size: 13, weight: .semibold))
          .foregroundStyle(Theme.accent)
          .opacity(stale ? 0.45 : 1)
          .help("Part of the set the “Open all” row opens")
          .transition(.opacity)
      }
      Confidence(probability: hit.jevProbability, emphasized: selected, stale: stale)
      if ready {
        Text("↵")
          .font(.system(size: 12, weight: .bold, design: .rounded))
          .frame(width: 24, height: 22)
          .background(Theme.ready.opacity(0.18), in: RoundedRectangle(cornerRadius: 6))
          .foregroundStyle(Theme.ready)
          .transition(.opacity)
      }
    }
    .padding(.horizontal, 12)
    .background(
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .fill(selected ? Theme.surface : Color.clear)
    )
    .animation(.easeOut(duration: 0.12), value: ready)
    .animation(.easeOut(duration: 0.12), value: hit.inSet)
    .contentShape(Rectangle())
    .accessibilityElement(children: .combine)
    .accessibilityLabel("\(hit.candidate.title), \(hit.candidate.kind.label)")
  }
}

/// Jev's probability that this row is the intended target. Quiet on every row but the selected one.
struct Confidence: View {
  let probability: Double?
  let emphasized: Bool
  let stale: Bool

  var body: some View {
    if let probability {
      let percent = Int((probability * 100).rounded())
      HStack(spacing: 8) {
        Capsule()
          .fill(Theme.faint.opacity(0.35))
          .frame(width: 40, height: 3)
          .overlay(alignment: .leading) {
            Capsule()
              .fill(emphasized ? Theme.accent : Theme.faint)
              .frame(width: 40 * CGFloat(min(max(probability, 0), 1)))
              .animation(.easeOut(duration: 0.15), value: probability)
          }
        Text("\(percent)%")
          .font(.system(size: 12, weight: .medium, design: .monospaced))
          .monospacedDigit()
          .foregroundStyle(emphasized ? Theme.text : Theme.faint)
          .frame(width: 38, alignment: .trailing)
      }
      .opacity(stale ? 0.45 : 1)
    }
  }
}

/// The real app or document icon where one exists; a tinted glyph for everything synthetic.
struct CandidateIcon: View {
  let candidate: Candidate

  var body: some View {
    switch candidate.payload {
    case .app(let url), .file(let url):
      Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
        .resizable()
        .interpolation(.high)
        .frame(width: 32, height: 32)
    case .group(let members):
      ZStack {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .fill(tint)
          .frame(width: 32, height: 32)
        Image(systemName: "square.stack.3d.up.fill")
          .font(.system(size: 14, weight: .semibold))
          .foregroundStyle(Theme.text)
        Text("\(members.count)")
          .font(.system(size: 9, weight: .bold, design: .rounded))
          .foregroundStyle(Theme.background)
          .padding(.horizontal, 4)
          .frame(height: 13)
          .background(Theme.accent, in: Capsule())
          .offset(x: 13, y: -12)
      }
      .frame(width: 32, height: 32)
    default:
      Image(systemName: symbol)
        .font(.system(size: 14, weight: .semibold))
        .foregroundStyle(Theme.text)
        .frame(width: 32, height: 32)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(tint))
    }
  }

  private var symbol: String {
    switch candidate.kind {
    case .openApp: return "app.fill"
    case .openFile: return "doc.fill"
    case .openURL: return "link"
    case .webSearch: return "globe"
    case .calculate: return "equal"
    case .systemToggle: return "switch.2"
    case .runShortcut: return "command"
    case .unclear: return "questionmark"
    }
  }

  private var tint: Color {
    switch candidate.kind {
    case .calculate: return Color(red: 0.95, green: 0.55, blue: 0.25)
    case .webSearch: return Color(red: 0.30, green: 0.55, blue: 0.95)
    case .openURL: return Color(red: 0.25, green: 0.62, blue: 0.85)
    case .systemToggle: return Color(red: 0.50, green: 0.52, blue: 0.60)
    case .runShortcut: return Color(red: 0.62, green: 0.40, blue: 0.95)
    default: return Theme.faint
    }
  }
}

struct EmptyHint: View {
  @ObservedObject var model: LauncherModel
  private let examples = [
    "dark", "wifi off", "15% of 240", "the pdf I just downloaded", "links I visited today",
  ]

  var body: some View {
    HStack(spacing: 8) {
      ForEach(examples, id: \.self) { example in
        Text(example)
          .font(.system(size: 12, weight: .medium, design: .monospaced))
          .foregroundStyle(Theme.dim)
          .padding(.horizontal, 11)
          .padding(.vertical, 6)
          .background(Theme.surface, in: Capsule())
          .onTapGesture { model.query = example }
      }
    }
    .padding(.horizontal, 24)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

/// Two numbers, nothing else: the last round-trip on the left, the running cost on the right.
/// Everything else (p50/p95, decisions, tokens) lives in the hover tooltip.
struct StatsFooter: View {
  @ObservedObject var model: LauncherModel

  var body: some View {
    let stats = model.stats
    HStack(spacing: 0) {
      if let error = model.lastError {
        Text(error)
          .foregroundStyle(Theme.danger)
          .lineLimit(1)
      } else if !model.hasAPIKey {
        Text("TYPESAFE_API_KEY not set")
          .foregroundStyle(Theme.danger)
      } else if let last = stats.lastMs {
        Text("\(ms(last)) ms")
          .foregroundStyle(tint(last))
          .fontWeight(.semibold)
      } else {
        Text("— ms")
          .foregroundStyle(Theme.faint)
      }
      Spacer(minLength: 12)
      Text(String(format: "$%.4f", stats.estimatedCostUSD))
        .foregroundStyle(stats.requests > 0 ? Theme.dim : Theme.faint)
    }
    .help(
      String(
        format: "p50 %@ ms · p95 %@ ms · %d decisions · %.0f input tokens per decision",
        ms(stats.p50Ms), ms(stats.p95Ms), stats.requests, stats.tokensPerDecision)
    )
    .font(.system(size: 12, weight: .regular, design: .monospaced))
    .monospacedDigit()
    .padding(.horizontal, 22)
  }

  private func ms(_ value: Double?) -> String {
    guard let value else { return "—" }
    return String(format: "%.0f", value)
  }

  private func tint(_ value: Double) -> Color {
    if value < 250 { return Theme.ready }
    if value < 600 { return Theme.warn }
    return Theme.danger
  }
}
