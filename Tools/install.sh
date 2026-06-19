#!/usr/bin/env bash
#
# Builds newmail and installs it to /Applications, registers that copy with
# LaunchServices, and (by default) sets it as the system's default mail client.
#
# A Debug build already deploys the app into /Applications (TARGET_BUILD_DIR in
# project.yml), which is also what happens when you run from Xcode — so this
# script is just the no-Xcode path plus the one-time default-handler setup.
#
# Usage:
#   Tools/install.sh               # build, install, register, set as default
#   Tools/install.sh --no-default  # skip setting newmail as the default mail app
#
# Note: resetting the registration can make macOS fall back to another mailto:
# handler, so the default is re-asserted on every run unless --no-default.
#
set -euo pipefail

cd "$(dirname "$0")/.."

BUNDLE_ID="com.meirt.newmail"
APP="/Applications/newmail.app"
LSREG="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

echo "==> Regenerating Xcode project"
xcodegen generate >/dev/null

echo "==> Quitting any running instance (can't overwrite a running bundle)"
osascript -e "tell application id \"$BUNDLE_ID\" to quit" 2>/dev/null || true
sleep 1
pkill -f "newmail.app/Contents/MacOS/newmail" 2>/dev/null || true
sleep 1

echo "==> Building (Debug, signed) into $APP"
# The Debug config's TARGET_BUILD_DIR points at /Applications, so the build
# deploys the app there directly; the post-build phase removes loose products.
xcodebuild -project newmail.xcodeproj -scheme newmail -configuration Debug \
  -destination 'platform=macOS' build >/dev/null

echo "==> Registering the /Applications copy with LaunchServices"
"$LSREG" -f "$APP"

if [ "${1:-}" != "--no-default" ]; then
  echo "==> Setting newmail as the default mail client"
  swift - "$BUNDLE_ID" <<'SWIFT'
import Foundation
import CoreServices
let bundleID = CommandLine.arguments[1] as NSString
let status = LSSetDefaultHandlerForURLScheme("mailto" as NSString, bundleID)
print("    mailto -> \(bundleID) (status \(status), 0 = success)")
SWIFT
fi

echo "==> Done. Default mailto handler:"
swift - <<'SWIFT'
import Foundation
import AppKit
if let app = NSWorkspace.shared.urlForApplication(toOpen: URL(string: "mailto:x@y.com")!) {
    print("    \(app.path)")
}
SWIFT
