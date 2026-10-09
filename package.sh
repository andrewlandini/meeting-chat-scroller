#!/bin/zsh
# Builds dist/MeetingChatScroller.pkg, which installs the app to /Applications and launches it.
set -euo pipefail
cd "$(dirname "$0")"

VERSION=1.1
./build.sh --no-install

rm -rf dist build/pkgroot
mkdir -p dist build/pkgroot
ditto --noextattr --noqtn --norsrc build/MeetingChatScroller.app build/pkgroot/MeetingChatScroller.app

COPYFILE_DISABLE=1 pkgbuild \
  --root build/pkgroot \
  --install-location /Applications \
  --identifier com.andrewlandini.meetingchatscroller \
  --version "$VERSION" \
  --scripts pkg-scripts \
  build/component.pkg

productbuild --package build/component.pkg "dist/MeetingChatScroller-$VERSION.pkg"
rm build/component.pkg
echo "Built dist/MeetingChatScroller-$VERSION.pkg"
