#!/usr/bin/env bash
set -euo pipefail

# -------------------------------------------------------------------
# reload_version.sh — tap-aware reloader for Homebrew formulae
#
# Supports two layouts:
#  A) All-in-one tap repo (code + Formula in the same repo)
#  B) Split repos   (source code in repo A, Formula in tap repo B)
#
# Usage examples:
#  # In a split layout, run this INSIDE THE SOURCE REPO and point to the tap:
#  ./reload_version.sh --tap raymonepping/homebrew-stack-refresher-cli \
#    --formula stack_refreshr_cli.rb --publish-gh-release
#
#  # In an all-in-one tap repo (like docker-janitor), run inside the tap:
#  ./reload_version.sh --formula stack_refreshr_cli.rb --publish-gh-release
#
# Optional flags:
#  --tap <owner/repo>        Tap repository slug (required for split layout)
#  --formula <file.rb>       Formula filename inside tap's Formula/ directory
#  --tag vX.Y.Z              Tag to publish (defaults to latest annotated tag in source)
#  --publish-gh-release      Create a GitHub Release if missing
#  --skip-reinstall          Do not reinstall via brew at the end
#  --sleep <seconds>         Wait before checking tarball (default 3)
# -------------------------------------------------------------------

# Defaults
PUBLISH_RELEASE=false
SKIP_REINSTALL=false
SLEEP_DURATION=3
EXPLICIT_TAG=""
TAP_SLUG=""
FORMULA_FILE_NAME=""

# Parse flags
while [[ $# -gt 0 ]]; do
  case "$1" in
    --tap) TAP_SLUG="$2"; shift 2 ;;
    --formula) FORMULA_FILE_NAME="$2"; shift 2 ;;
    --tag) EXPLICIT_TAG="$2"; shift 2 ;;
    --publish-gh-release) PUBLISH_RELEASE=true; shift ;;
    --skip-reinstall) SKIP_REINSTALL=true; shift ;;
    --sleep) SLEEP_DURATION="$2"; shift 2 ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

# Helpers
have() { command -v "$1" >/dev/null 2>&1; }
die() { echo "❌ $*" >&2; exit 1; }
say() { echo "$*"; }

# Where are we running?
PROJECT_ROOT="$(pwd)"

# Resolve the current repo's origin as HTTPS slug: owner/repo
current_repo_https() {
  local url
  url="$(git -C "$PROJECT_ROOT" remote get-url origin 2>/dev/null || true)" || true
  [[ -z "$url" ]] && die "No git origin found. Run inside a git repo."
  # Normalize git@github.com:owner/repo.git or https URLs to https://github.com/owner/repo
  url="${url%.git}"
  url="${url/git@github.com:/https://github.com/}"
  url="${url/ssh:\/\/git@github.com\//https://github.com/}"
  # Extract owner/repo
  echo "${url#https://github.com/}"
}

SOURCE_SLUG="$(current_repo_https)"   # e.g., raymonepping/stack-refreshr or raymonepping/homebrew-stack-refresher-cli
SOURCE_URL="https://github.com/${SOURCE_SLUG}"

# Detect layout: tap-or-not by name
is_tap_like=0
[[ "$SOURCE_SLUG" =~ ^[^/]+/homebrew- ]] && is_tap_like=1

# If running in a tap, default the tap slug to this repo
if [[ $is_tap_like -eq 1 && -z "$TAP_SLUG" ]]; then
  TAP_SLUG="$SOURCE_SLUG"
fi

# Require TAP_SLUG in split layout
if [[ $is_tap_like -eq 0 && -z "$TAP_SLUG" ]]; then
  die "Split layout detected. Provide your tap slug with --tap <owner/repo>, e.g. --tap raymonepping/homebrew-stack-refresher-cli"
fi

# Determine tag
if [[ -n "$EXPLICIT_TAG" ]]; then
  TAG="$EXPLICIT_TAG"
else
  # Prefer latest annotated tag
  TAG="$(git -C "$PROJECT_ROOT" describe --tags --abbrev=0 2>/dev/null || true)"
  [[ -z "$TAG" ]] && die "No git tags found. Use --tag vX.Y.Z or create a tag in the source repo."
fi
VERSION="${TAG#v}"   # drop leading v for formula's version field

say ""
say "📦 Preparing release for ${SOURCE_SLUG} @ ${TAG}"
say "    Layout: $([[ $is_tap_like -eq 1 ]] && echo 'tap (all-in-one)' || echo 'split (source + tap)')"
say "    Tap:     ${TAP_SLUG}"
say "    Version: ${VERSION}"

# Tarball URL always comes from the SOURCE repo (even if we're also the tap)
TARBALL_URL="${SOURCE_URL}/archive/refs/tags/${TAG}.tar.gz"

say "⏳ Waiting ${SLEEP_DURATION}s for GitHub to process tag..."
sleep "${SLEEP_DURATION}"

# ---------- Robust tarball availability check (follow redirects, fail fast)
say "🔎 Checking tarball availability at:"
say "    ${TARBALL_URL}"
attempt=0
until command curl -sSfL -o /dev/null "$TARBALL_URL" >/dev/null 2>&1 || (( attempt >= 10 )); do
  attempt=$((attempt + 1))
  echo "⏳ Tarball not ready yet. Retrying (${attempt}/10)..."
  sleep 2
done
command curl -sSfL -o /dev/null "$TARBALL_URL" >/dev/null 2>&1 || die "Tarball still not available: ${TARBALL_URL}"

# Compute SHA256 (same flags)
SHA256="$(command curl -sSL "$TARBALL_URL" | shasum -a 256 | awk '{print $1}')"
say "🔐 SHA256: ${SHA256}"

# Prepare tap working copy (clone to temp if needed)
WORKDIR="$(mktemp -d)"
cleanup() { rm -rf "$WORKDIR"; }
trap cleanup EXIT

say "📥 Fetching tap ${TAP_SLUG} into temp workspace…"
git -C "$WORKDIR" clone "https://github.com/${TAP_SLUG}.git" tap >/dev/null 2>&1
TAP_ROOT="$WORKDIR/tap"

# Locate formula file in tap
if [[ -z "$FORMULA_FILE_NAME" ]]; then
  # pick first .rb in Formula/ if not provided
  FORMULA_FILE_PATH="$(find "$TAP_ROOT/Formula" -maxdepth 1 -name '*.rb' | head -n 1)"
else
  FORMULA_FILE_PATH="$TAP_ROOT/Formula/$FORMULA_FILE_NAME"
fi
[[ -f "$FORMULA_FILE_PATH" ]] || die "Formula file not found in tap: ${FORMULA_FILE_PATH}"

FORMULA_BASENAME="$(basename "$FORMULA_FILE_PATH" .rb)"   # token for brew
say "🧪 Using Formula: ${FORMULA_BASENAME} (file: $(basename "$FORMULA_FILE_PATH"))"

# Patch formula: url, sha256, version
# Replace first occurrence of url/sha256/version lines
# Safe edits with Ruby DSL patterns to avoid collateral damage
sed -i '' -E "0,/^ *url \".*\"/s||  url \"${TARBALL_URL}\"|" "$FORMULA_FILE_PATH"
sed -i '' -E "0,/^ *sha256 \".*\"/s||  sha256 \"${SHA256}\"|" "$FORMULA_FILE_PATH"
if grep -qE '^ *version "' "$FORMULA_FILE_PATH"; then
  sed -i '' -E "0,/^ *version \".*\"/s||  version \"${VERSION}\"|" "$FORMULA_FILE_PATH"
else
  # Insert version under sha256 if missing
  awk -v ver="$VERSION" '
    {print}
    /^ *sha256 "/ && !vprinted {print "  version \"" ver "\""; vprinted=1}
  ' "$FORMULA_FILE_PATH" > "$FORMULA_FILE_PATH.tmp" && mv "$FORMULA_FILE_PATH.tmp" "$FORMULA_FILE_PATH"
fi

pushd "$TAP_ROOT" >/dev/null
if git diff --quiet -- "$FORMULA_FILE_PATH"; then
  say "ℹ️ No changes to commit in tap."
else
  git add "$FORMULA_FILE_PATH"
  git commit -m "🔖 ${FORMULA_BASENAME}: release ${TAG}"
  git push
  say "📝 Tap updated: ${TAP_SLUG}/$(basename "$FORMULA_FILE_PATH")"
fi
popd >/dev/null

# Create GitHub Release (optional)
if [[ "$PUBLISH_RELEASE" == true ]]; then
  if have gh; then
    say "📣 Publishing GitHub release (source repo)…"
    gh release view "$TAG" >/dev/null 2>&1 || gh release create "$TAG" --repo "$SOURCE_SLUG" --title "${SOURCE_SLUG##*/} ${VERSION}" --notes "Release ${VERSION}" || true
    say "🌐 ${SOURCE_URL}/releases/tag/${TAG}"
  else
    say "ℹ️ gh not installed; skip publishing GH release."
  fi
fi

# Reinstall via brew (from tap)
if [[ "$SKIP_REINSTALL" == true ]]; then
  say "⏭️  Skipping reinstall as requested (--skip-reinstall)."
else
  say "🍺 Reinstalling via Homebrew from tap…"

  # ---------- Fix a known-bad tap remote (SSH to localhost:2222) without untapping
  if TAP_DIR="$(brew --repo hashicorp/security 2>/dev/null)"; then
    if [ -f "$TAP_DIR/.git/config" ] && grep -q 'localhost:2222' "$TAP_DIR/.git/config"; then
      say "🔧 Fixing hashicorp/security tap remote (switching to HTTPS)…"
      git -C "$TAP_DIR" remote set-url origin https://github.com/hashicorp/homebrew-security.git || true
      git -C "$TAP_DIR" fetch origin || true
    fi
  fi

  # Optional: quiet install (no auto-update)
  HOMEBREW_NO_AUTO_UPDATE=1 brew install "${TAP_SLUG}/${FORMULA_BASENAME}"

  # Fix common completion link conflicts automatically
  say "🔗 Relinking with overwrite to resolve completion conflicts…"
  brew link --overwrite --force "${FORMULA_BASENAME}" || true

  # Smoke test
  BIN_NAME="${FORMULA_BASENAME//-/_}"  # token → binary heuristic if formula installs wrapper with different name, adjust if needed
  case "$FORMULA_BASENAME" in
    stack_refreshr_cli) BIN_NAME="stack_refreshr" ;;
  esac

  if command -v "$BIN_NAME" >/dev/null 2>&1; then
    say "✅ Installed: $("$BIN_NAME" --help | head -n 1)"
  else
    say "⚠️ Binary not found on PATH. Try: brew link --overwrite --force ${FORMULA_BASENAME}"
  fi
fi

say "✅ Done."
