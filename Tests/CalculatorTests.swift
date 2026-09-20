import XCTest

@testable import Intern

final class CalculatorTests: XCTestCase {
  func testBasicArithmeticAndPrecedence() {
    XCTAssertEqual(Calculator.evaluate("2+3*4")?.value, 14)
    XCTAssertEqual(Calculator.evaluate("(2+3)*4")?.value, 20)
    XCTAssertEqual(Calculator.evaluate("2^10")?.value, 1024)
    XCTAssertEqual(Calculator.evaluate("-3 + 5")?.value, 2)
    XCTAssertEqual(Calculator.evaluate("sqrt(81)")?.value, 9)
    XCTAssertEqual(Calculator.evaluate("3 x 4")?.value, 12)
  }

  func testPercentForms() {
    XCTAssertEqual(Calculator.evaluate("calc 15% of 240")?.value, 36)
    XCTAssertEqual(Calculator.evaluate("15 percent of 240")?.value, 36)
    XCTAssertEqual(Calculator.evaluate("= 200 * 10%")?.value, 20)
  }

  func testKeepsOriginalExpressionForDisplay() {
    let evaluation = Calculator.evaluate("  calc 15% of 240 ")
    XCTAssertEqual(evaluation?.expression, "calc 15% of 240")
    XCTAssertEqual(evaluation?.formatted, "36")
  }

  func testRejectsNonMath() {
    XCTAssertNil(Calculator.evaluate("dark"))
    XCTAssertNil(Calculator.evaluate("wifi off"))
    XCTAssertNil(Calculator.evaluate("the pdf I just downloaded"))
    XCTAssertNil(Calculator.evaluate("240"))
    XCTAssertNil(Calculator.evaluate("2+"))
    XCTAssertNil(Calculator.evaluate("1/0"))
    XCTAssertNil(Calculator.evaluate("(2+3"))
  }

  func testFormatting() {
    XCTAssertEqual(Calculator.format(36), "36")
    XCTAssertEqual(Calculator.format(1.0 / 3.0), "0.333333")
    XCTAssertEqual(Calculator.format(-2.5), "-2.5")
  }
}
