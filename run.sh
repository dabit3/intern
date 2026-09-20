#!/bin/sh
# Builds the Debug app and launches it from the shell so TYPESAFE_API_KEY is inherited.
# Usage: ./run.sh [--show]
set -e
cd "$(dirname "$0")"
xcodebuild -project Intern.xcodeproj -scheme Intern -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath build CODE_SIGNING_ALLOWED=NO build -quiet
pkill -x Intern 2>/dev/null || true
exec ./build/Build/Products/Debug/Intern.app/Contents/MacOS/Intern "$@"
