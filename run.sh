#!/bin/sh
# Builds the Debug app and launches it from the shell so TYPESAFE_API_KEY is inherited.
# Usage: ./run.sh [--show]
set -e
cd "$(dirname "$0")"
APP="$PWD/build/Build/Products/Debug/Intern.app"
xcrun swift -e '
import AppKit
let apps = NSRunningApplication.runningApplications(
  withBundleIdentifier: "com.devin.typesafe.jev-launcher.debug"
).filter { $0.executableURL?.path == CommandLine.arguments[1] }
for app in apps { _ = app.terminate() }
let deadline = Date().addingTimeInterval(5)
while apps.contains(where: { !$0.isTerminated }), Date() < deadline {
  RunLoop.current.run(until: Date().addingTimeInterval(0.05))
}
guard apps.allSatisfy(\.isTerminated) else {
  FileHandle.standardError.write(Data("Quit Intern Dev before rebuilding.\n".utf8))
  exit(1)
}
' "$APP/Contents/MacOS/Intern"
xcodebuild -project Intern.xcodeproj -scheme Intern -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath build CODE_SIGNING_ALLOWED=NO build -quiet
exec "$APP/Contents/MacOS/Intern" "$@"
