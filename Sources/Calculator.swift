import Foundation

/// A small, safe arithmetic evaluator. No `NSExpression`, no dynamic code: a hand-written
/// recursive-descent parser over a fixed grammar.
///
/// Grammar: expr := term (('+'|'-') term)* ; term := unary (('*'|'/'|'x'|'%' ) unary)* ;
/// unary := '-' unary | power ; power := primary ('^' unary)? ;
/// primary := number '%'? | '(' expr ')' | 'sqrt' '(' expr ')'
/// Also accepts natural forms such as `15% of 240`, `calc 2+2`, `= 3*4`.
enum Calculator {
  struct Evaluation: Equatable, Sendable {
    let expression: String
    let value: Double
    var formatted: String { Calculator.format(value) }
  }

  static func evaluate(_ raw: String) -> Evaluation? {
    var text = raw.trimmingCharacters(in: .whitespaces).lowercased()
    for prefix in ["calculate ", "calc ", "= ", "="] where text.hasPrefix(prefix) {
      text = String(text.dropFirst(prefix.count))
      break
    }
    text = text.replacingOccurrences(of: " percent of ", with: "% of ")
    text = text.replacingOccurrences(of: "% of ", with: "%*")
    text = text.replacingOccurrences(of: "percent", with: "%")
    text = text.replacingOccurrences(of: ",", with: "")
    text = text.replacingOccurrences(of: "×", with: "*")
    text = text.replacingOccurrences(of: "÷", with: "/")
    text = text.trimmingCharacters(in: .whitespaces)
    guard text.contains(where: { $0.isNumber }) else { return nil }
    guard text.contains(where: { "+-*/^%x(".contains($0) }) || text.hasPrefix("sqrt") else {
      return nil
    }
    var parser = Parser(Array(text.replacingOccurrences(of: " ", with: "")))
    guard let value = parser.parseExpression(), parser.atEnd, value.isFinite else { return nil }
    return Evaluation(expression: raw.trimmingCharacters(in: .whitespaces), value: value)
  }

  static func format(_ value: Double) -> String {
    if value == value.rounded(), abs(value) < 1e15 {
      return String(Int64(value))
    }
    let formatter = NumberFormatter()
    formatter.numberStyle = .decimal
    formatter.maximumFractionDigits = 6
    formatter.usesGroupingSeparator = false
    return formatter.string(from: NSNumber(value: value)) ?? String(value)
  }

  private struct Parser {
    let chars: [Character]
    var position = 0

    init(_ chars: [Character]) { self.chars = chars }

    var atEnd: Bool { position >= chars.count }
    var current: Character? { atEnd ? nil : chars[position] }

    mutating func parseExpression() -> Double? {
      guard var value = parseTerm() else { return nil }
      while let op = current, op == "+" || op == "-" {
        position += 1
        guard let rhs = parseTerm() else { return nil }
        value = op == "+" ? value + rhs : value - rhs
      }
      return value
    }

    mutating func parseTerm() -> Double? {
      guard var value = parseUnary() else { return nil }
      while let op = current, op == "*" || op == "/" || op == "x" {
        position += 1
        guard let rhs = parseUnary() else { return nil }
        if op == "/" {
          guard rhs != 0 else { return nil }
          value /= rhs
        } else {
          value *= rhs
        }
      }
      return value
    }

    mutating func parseUnary() -> Double? {
      if current == "-" {
        position += 1
        return parseUnary().map { -$0 }
      }
      return parsePower()
    }

    mutating func parsePower() -> Double? {
      guard let base = parsePrimary() else { return nil }
      if current == "^" {
        position += 1
        guard let exponent = parseUnary() else { return nil }
        return pow(base, exponent)
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
      if matches("sqrt(") {
        position += 5
        guard let inner = parseExpression(), current == ")", inner >= 0 else { return nil }
        position += 1
        return applyPercent(inner.squareRoot())
      }
      let start = position
      while let c = current, c.isNumber || c == "." { position += 1 }
      guard position > start, let number = Double(String(chars[start..<position])) else {
        return nil
      }
      return applyPercent(number)
    }

    private mutating func applyPercent(_ value: Double) -> Double {
      if current == "%" {
        position += 1
        return value / 100
      }
      return value
    }

    private func matches(_ literal: String) -> Bool {
      let needed = Array(literal)
      guard position + needed.count <= chars.count else { return false }
      return Array(chars[position..<(position + needed.count)]) == needed
    }
  }
}
