#!/usr/bin/env bash
#
# Builds newmail and installs it to /Applications as a signed copy, then makes
# that the single registered copy and (optionally) the default mail client.
#
# Why: when you run from Xcode the build lives in DerivedData, whose path can
# change and which competes with any other copy as the system's mailto: handler.
# This keeps exactly one stable copy in /Applications and points macOS at it.
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
DERIVED="build/install"
PRODUCT="$DERIVED/Build/Products/Debug/newmail.app"
LSREG="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

echo "==> Regenerating Xcode project"
xcodegen generate >/dev/null

echo "==> Building (Debug, signed)"
rm -rf "$DERIVED"
xcodebuild -project newmail.xcodeproj -scheme newmail -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath "$DERIVED" build >/dev/null

echo "==> Quitting any running instance"
osascript -e "tell application id \"$BUNDLE_ID\" to quit" 2>/dev/null || true
sleep 1
pkill -f "newmail.app/Contents/MacOS/newmail" 2>/dev/null || true
sleep 1

echo "==> Installing to $APP"
rm -rf "$APP"
ditto "$PRODUCT" "$APP"

echo "==> Removing the build product so only /Applications remains on disk"
# LaunchServices re-discovers any newmail.app it finds on disk during background
# scans, so a lingering build copy would re-register and compete as the mailto:
# handler. Delete it; /Applications is the only copy we keep.
rm -rf "$DERIVED"

echo "==> Resetting LaunchServices registration to the /Applications copy only"
# Drop any stray DerivedData / build copies still registered (e.g. a previous
# Xcode run) so they can't hijack the mailto: handler.
while IFS= read -r path; do
  [ "$path" = "$APP" ] || "$LSREG" -u "$path" 2>/dev/null || true
done < <("$LSREG" -dump 2>/dev/null | awk '/path:.*newmail\.app/ {print $2}' | sort -u)
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
