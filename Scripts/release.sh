#!/bin/sh
# Builds a release zip, signs it for Sparkle and adds it to appcast.xml.
# Publishes nothing: it prints the commands that do.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

VERSION=${1:-}
case "$VERSION" in
    '' | *[!0-9.]* | .* | *. | *..*)
        echo "usage: sh Scripts/release.sh <version>, for example 1.3" >&2
        exit 64
        ;;
esac

PLIST=Resources/Info.plist
if [ "$(git rev-parse --abbrev-ref HEAD)" != main ] || [ -n "$(git status --porcelain)" ]; then
    echo "Release from a clean main, so the zip matches the tag." >&2
    exit 1
fi
if plutil -extract SUPublicEDKey raw "$PLIST" | grep -q REPLACE; then
    echo "SUPublicEDKey in $PLIST is still the placeholder. See Releasing in README.md." >&2
    exit 1
fi
if grep -q "<sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>" appcast.xml; then
    echo "appcast.xml already has $VERSION" >&2
    exit 1
fi

# The private signing key lives in 1Password only; `op` asks for Touch ID. Read it before the
# build, so a missing key stops the release before anything changes.
KEY_REF=${SPARKLE_KEY_REF:-op://Private/git-sight Sparkle key/private key}
if ! command -v op >/dev/null; then
    echo "The 1Password CLI (op) is needed to sign the update." >&2
    exit 1
fi
KEY=$(op read "$KEY_REF") || { echo "Couldn't read the signing key from $KEY_REF" >&2; exit 1; }

# Sparkle compares CFBundleVersion, so it has to grow with every release.
BUILD=$(git rev-list --count HEAD)
LAST=$(sed -n 's|.*<sparkle:version>\(.*\)</sparkle:version>.*|\1|p' appcast.xml | head -n 1)
if [ -n "$LAST" ] && [ "$BUILD" -le "$LAST" ]; then
    echo "Build $BUILD is not above the last released build $LAST. Was main rewritten?" >&2
    exit 1
fi
# sed, not plutil -replace, which rewrites the whole file with tabs.
set_plist() {
    sed -i '' "/<key>$1<\/key>/{n;s|<string>.*</string>|<string>$2</string>|;}" "$PLIST"
}
set_plist CFBundleShortVersionString "$VERSION"
set_plist CFBundleVersion "$BUILD"

sh Scripts/package_app.sh

ZIP=Artifacts/GitSight-$VERSION.zip
rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent Artifacts/GitSight.app "$ZIP"

SIGNATURE=$(printf '%s' "$KEY" | .build/artifacts/sparkle/Sparkle/bin/sign_update --ed-key-file - "$ZIP")
unset KEY

TAG=v$VERSION
MINIMUM=$(plutil -extract LSMinimumSystemVersion raw "$PLIST")
ITEM="    <item>
      <title>$VERSION</title>
      <pubDate>$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')</pubDate>
      <link>https://github.com/nuanu-ai/git-sight/releases/tag/$TAG</link>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>$MINIMUM</sparkle:minimumSystemVersion>
      <enclosure url=\"https://github.com/nuanu-ai/git-sight/releases/download/$TAG/GitSight-$VERSION.zip\" type=\"application/octet-stream\" $SIGNATURE />
    </item>"

# Newest first: the item goes above the previous releases.
ITEM=$ITEM awk '!done && (/<item>/ || /<\/channel>/) { print ENVIRON["ITEM"]; done = 1 } { print }' appcast.xml > appcast.xml.new
mv appcast.xml.new appcast.xml

cat <<EOF

$ZIP is signed and appcast.xml lists $VERSION (build $BUILD).
Publish the zip before main gets the new appcast, so the app never sees a link that is not there yet:

  git commit -m "release: $VERSION" $PLIST appcast.xml
  git tag $TAG
  git push origin $TAG
  gh release create $TAG $ZIP --verify-tag --title "git-sight $VERSION" --notes "..."
  git push origin main
EOF
