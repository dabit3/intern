import Foundation

/// A small, safe arithmetic evaluator. No `NSExpression`, no dynamic code: a hand-written
/// recursive-descent parser over a fixed grammar.
///
/// Grammar: expr := term (('+'|'-') term)* ; term := unary (('*'|'/'|'x') unary)* ;
/// unary := ('+'|'-') unary | power ; power := primary ('^' unary)? ;
/// primary := number '%'? | '(' expr ')' | 'sqrt' '(' expr ')'
/// Also accepts natural forms such as `15% of 240`, `calc 2+2`, `= 3*4`.
enum Calculator {
  struct Evaluation: Equatable, Sendable {
    let expression: String
    let value: Double
    var formatted: String { Calculator.format(value) }
  }

  static func evaluate(_ raw: String) -> Evaluation? {
    guard raw.utf8.prefix(4097).count <= 4096 else { return nil }
    var text = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    var explicit = false
    if text.hasPrefix("=") {
      text.removeFirst()
      explicit = true
    } else {
      for prefix in ["calculate", "calc"]
      where text.hasPrefix(prefix) && text.dropFirst(prefix.count).first?.isWhitespace == true {
        text = String(text.dropFirst(prefix.count))
        explicit = true
        break
      }
    }
    text = text.replacingOccurrences(of: "percent", with: "%")
    text = text.replacingOccurrences(of: #"%\s*of\s+"#, with: "%*", options: .regularExpression)
    text = text.replacingOccurrences(of: "−", with: "-")
    text = text.replacingOccurrences(of: "×", with: "*")
    text = text.replacingOccurrences(of: "÷", with: "/")
    guard text.contains(where: { $0.isNumber }) else { return nil }
    guard explicit || text.contains(where: { "+-*/^%x(√e".contains($0) }) else {
      return nil
    }
    var parser = Parser(Array(text))
    guard let value = parser.parseExpression(), parser.atEnd, value.isFinite else { return nil }
    return Evaluation(expression: raw.trimmingCharacters(in: .whitespacesAndNewlines), value: value)
  }

  static func format(_ value: Double) -> String {
    guard value.isFinite else { return "Undefined" }
    if value == value.rounded(), abs(value) < 1e15 {
      return String(Int64(value))
    }
    if abs(value) < 0.000001 || abs(value) >= 1e15 {
      return String(value)
    }
    let formatter = NumberFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.numberStyle = .decimal
    formatter.maximumFractionDigits = 6
    formatter.usesGroupingSeparator = false
    return formatter.string(from: NSNumber(value: value)) ?? String(value)
  }

  private struct Parser {
    let chars: [Character]
    var position = 0
    var depth = 0

    init(_ chars: [Character]) { self.chars = chars }

    var atEnd: Bool { position >= chars.count }
    var current: Character? { atEnd ? nil : chars[position] }

    mutating func parseExpression() -> Double? {
      guard var value = parseTerm() else { return nil }
      while let op = current, op == "+" || op == "-" {
        position += 1
        guard let rhs = parseTerm() else { return nil }
        value = op == "+" ? value + rhs : value - rhs
        guard value.isFinite else { return nil }
      }
      return value
    }

    mutating func parseTerm() -> Double? {
      guard var value = parseUnary() else { return nil }
      while let op = current,
        op == "*" || op == "/" || op == "x" || op == "(" || op == "√" || matches("sqrt")
      {
        if op == "*" || op == "/" || op == "x" { position += 1 }
        guard let rhs = parseUnary() else { return nil }
        if op == "/" {
          guard rhs != 0 else { return nil }
          value /= rhs
        } else {
          value *= rhs
        }
        guard value.isFinite else { return nil }
      }
      return value
    }

    mutating func parseUnary() -> Double? {
      guard depth < 64 else { return nil }
      depth += 1
      defer { depth -= 1 }
      skipWhitespace()
      if current == "-" || current == "+" {
        let negative = current == "-"
        position += 1
        return parseUnary().map { negative ? -$0 : $0 }
      }
      return parsePower()
    }

    mutating func parsePower() -> Double? {
      guard let base = parsePrimary() else { return nil }
      if current == "^" {
        position += 1
        guard let exponent = parseUnary() else { return nil }
        let value = pow(base, exponent)
        return value.isFinite ? value : nil
      }
      return base
    }

    mutating func parsePrimary() -> Double? {
      if current == "(" {
        position += 1
        guard let inner = parseExpression(), current == ")" else { return nil }
        position += 1
        return applyPercent(inner)
      }
      if current == "√" {
        position += 1
        guard let inner = parseUnary(), inner >= 0 else { return nil }
        return inner.squareRoot()
      }
      if matches("sqrt") {
        position += 4
        skipWhitespace()
        guard current == "(" else { return nil }
        position += 1
        guard let inner = parseExpression(), current == ")", inner >= 0 else { return nil }
        position += 1
        return applyPercent(inner.squareRoot())
      }
      let start = position
      while let c = current, isDigit(c) || c == "." || c == "," { position += 1 }
      let mantissa = String(chars[start..<position])
      let parts = mantissa.split(separator: ".", omittingEmptySubsequences: false)
      guard parts.count <= 2, mantissa.contains(where: isDigit) else { return nil }
      let groups = parts[0].split(separator: ",", omittingEmptySubsequences: false)
      if groups.count > 1 {
        guard (1...3).contains(groups[0].count),
          groups.allSatisfy({ $0.allSatisfy(isDigit) }),
          groups.dropFirst().allSatisfy({ $0.count == 3 })
        else { return nil }
      }
      if parts.count == 2, !parts[1].allSatisfy(isDigit) { return nil }
      if current == "e" {
        position += 1
        if current == "+" || current == "-" { position += 1 }
        let exponentStart = position
        while let c = current, isDigit(c) { position += 1 }
        guard position > exponentStart else { return nil }
      }
      guard
        let number = Double(
          String(chars[start..<position]).replacingOccurrences(of: ",", with: "")),
        number.isFinite
      else {
        return nil
      }
      return applyPercent(number)
    }

    private mutating func applyPercent(_ value: Double) -> Double {
      skipWhitespace()
      if current == "%" {
        position += 1
        skipWhitespace()
        return value / 100
      }
      return value
    }

    private mutating func skipWhitespace() {
      while let c = current, c.isWhitespace { position += 1 }
    }

    private func isDigit(_ character: Character) -> Bool {
      character >= "0" && character <= "9"
    }

    private func matches(_ literal: String) -> Bool {
      let needed = Array(literal)
      guard position + needed.count <= chars.count else { return false }
      return Array(chars[position..<(position + needed.count)]) == needed
    }
  }
}
