#!/usr/bin/env bash
# Installs the whk CLI on a GitHub Actions runner: downloads the release
# archive for the runner's platform from github.com/kroqdotdev/webhooks-cc,
# checks it against the release's checksums.txt, and puts the binary on PATH
# for the steps that follow. The same steps as https://webhooks.cc/install.sh,
# with the runner's files (GITHUB_PATH, GITHUB_ENV, GITHUB_OUTPUT) in place of
# /usr/local/bin.
#
# Reads SETUP_WHK_VERSION ("latest", "1.10.0" or "v1.10.0") and
# SETUP_WHK_API_KEY (optional). SETUP_WHK_INSTALL_DIR overrides where the
# binary goes, which is $RUNNER_TEMP/setup-whk/bin otherwise.
set -euo pipefail

REPO="kroqdotdev/webhooks-cc"
RELEASES="https://github.com/$REPO/releases"

# Cosign keyless verification parameters (GitHub Actions OIDC), as in install.sh.
COSIGN_ISSUER="https://token.actions.githubusercontent.com"
COSIGN_IDENTITY_REGEXP="^https://github.com/$REPO/"

# An error the run's summary shows, then stop. Workflow commands are one line.
fail() {
  echo "::error title=setup-whk::$*"
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "Required command not found on this runner: $1"
}

fetch() {
  curl -fsSL --retry 3 "$1" -o "$2"
}

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

# A path as the runner's own tools read it: Windows form on Windows.
native_path() {
  if [ "$os" = "windows" ] && command -v cygpath >/dev/null 2>&1; then
    cygpath -w "$1"
  else
    printf '%s\n' "$1"
  fi
}

# A path as this shell reads it: the runner gives Windows paths on Windows.
shell_path() {
  if [ "$os" = "windows" ] && command -v cygpath >/dev/null 2>&1; then
    cygpath -u "$1"
  else
    printf '%s\n' "$1"
  fi
}

require_cmd curl
require_cmd awk
require_cmd mktemp
command -v sha256sum >/dev/null 2>&1 || command -v shasum >/dev/null 2>&1 ||
  fail "sha256sum or shasum is required to verify the download"

# --- The API key --------------------------------------------------------------
# First, so the key is masked before anything else can go wrong. whk reads
# WHK_API_KEY only together with WHK_AUTH=key; the SDKs read WHK_API_KEY alone.

api_key="${SETUP_WHK_API_KEY:-}"
# A secret pasted with a trailing newline is still one key.
api_key="${api_key#"${api_key%%[![:space:]]*}"}"
api_key="${api_key%"${api_key##*[![:space:]]}"}"
if [ -n "$api_key" ]; then
  # Mask before judging it, so a refused value is hidden too. A mask covers
  # one line, so a value of several lines is masked line by line.
  while IFS= read -r line; do
    [ -z "$line" ] || echo "::add-mask::$line"
  done <<<"$api_key"
  case "$api_key" in
    *[[:space:]]*) fail "The api-key input must be one line without spaces" ;;
  esac
fi

# --- Platform -----------------------------------------------------------------

os="${RUNNER_OS:-$(uname -s)}"
case "$os" in
  Linux) os="linux" ;;
  macOS | Darwin) os="darwin" ;;
  Windows | MINGW* | MSYS* | CYGWIN*) os="windows" ;;
  *) fail "whk has no build for this operating system: $os" ;;
esac

arch="${RUNNER_ARCH:-$(uname -m)}"
case "$arch" in
  X64 | x86_64 | amd64) arch="x86_64" ;;
  ARM64 | arm64 | aarch64) arch="aarch64" ;;
  *) fail "whk has no build for this architecture: $arch" ;;
esac

# Every release holds each archive twice: under its target's name, and under
# the short name the first whk releases used (kept so they can still update).
# The short one is the second place to look when a download fails.
binary="whk"
archive="tar.gz"
case "${os}_${arch}" in
  linux_x86_64)
    target="x86_64-unknown-linux-gnu"
    other_name="whk_linux_amd64.tar.gz"
    ;;
  linux_aarch64)
    target="aarch64-unknown-linux-gnu"
    other_name="whk_linux_arm64.tar.gz"
    ;;
  darwin_x86_64)
    target="x86_64-apple-darwin"
    other_name="whk_darwin_amd64.tar.gz"
    ;;
  darwin_aarch64)
    target="aarch64-apple-darwin"
    other_name="whk_darwin_arm64.tar.gz"
    ;;
  windows_x86_64)
    target="x86_64-pc-windows-msvc"
    other_name="whk_windows_amd64.zip"
    binary="whk.exe"
    archive="zip"
    ;;
  windows_aarch64)
    fail "whk has no Windows ARM64 build yet. Use a Windows x64, Linux or macOS runner."
    ;;
  *) fail "whk has no build for this platform: ${os}/${arch}" ;;
esac

# --- Version ------------------------------------------------------------------

requested="${SETUP_WHK_VERSION:-latest}"
if [ -z "$requested" ] || [ "$requested" = "latest" ]; then
  # The releases page redirects "latest" to the newest release's tag. That
  # is a plain page, not the API, so it needs no token and has no rate limit
  # for a runner's shared address to run into.
  latest_url="$(curl -fsSLI --retry 3 -o /dev/null -w '%{url_effective}' "$RELEASES/latest")" ||
    fail "Could not find the latest whk release at $RELEASES/latest"
  tag="${latest_url##*/}"
else
  tag="v${requested#v}"
fi

# In a variable, so every bash (macOS ships 3.2) reads the pattern the same way.
version_pattern='^v[0-9]+\.[0-9]+\.[0-9]+([-+][0-9A-Za-z.+-]+)?$'
if ! [[ "$tag" =~ $version_pattern ]]; then
  fail "Not a whk version: \"${requested}\" (resolved to \"${tag}\"). Use \"latest\" or a version such as 1.10.0."
fi
case "$tag" in
  v0.*) fail "setup-whk installs whk 1.0.0 and later; $tag was released in another archive format." ;;
esac
version="${tag#v}"

filename="whk-${tag}-${target}.${archive}"
release_base="$RELEASES/download/${tag}"

echo "Installing whk $version ($target)"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# --- Download and verify ------------------------------------------------------

fetch "$release_base/checksums.txt" "$work/checksums.txt" ||
  fail "Could not download the checksums of whk $version. Is it a released version? See $RELEASES"

# The checksums file is signed with cosign (keyless). Checked when cosign is
# on the runner, for example after sigstore/cosign-installer.
if curl -fsSL --retry 3 "$release_base/checksums.txt.sigstore.json" \
  -o "$work/checksums.txt.sigstore.json" >/dev/null 2>&1; then
  if command -v cosign >/dev/null 2>&1; then
    cosign verify-blob \
      --bundle "$work/checksums.txt.sigstore.json" \
      --certificate-oidc-issuer "$COSIGN_ISSUER" \
      --certificate-identity-regexp "$COSIGN_IDENTITY_REGEXP" \
      "$work/checksums.txt" >/dev/null 2>&1 ||
      fail "The cosign signature of checksums.txt for whk $version did not verify."
    echo "Signature verified (cosign keyless)."
  else
    echo "cosign is not installed, so the checksums file's signature was not checked."
  fi
else
  echo "::warning title=setup-whk::whk $version has no signature bundle; the download is checked against its checksum only."
fi

if ! fetch "$release_base/$filename" "$work/$filename"; then
  echo "Could not download $filename; trying the release's other copy, $other_name."
  filename="$other_name"
  fetch "$release_base/$filename" "$work/$filename" ||
    fail "Could not download the $target archive of whk $version from $RELEASES/tag/$tag"
fi

# Whichever copy came down is checked against its own line in checksums.txt.
expected="$(awk -v f="$filename" '$2 == f || $2 == ("*" f) { print $1; exit }' "$work/checksums.txt")"
[ -n "$expected" ] || fail "checksums.txt of whk $version has no entry for $filename"
actual="$(sha256_file "$work/$filename")"
[ "$actual" = "$expected" ] || fail "Checksum verification failed for $filename"
echo "Checksum verified."

# --- Extract and install ------------------------------------------------------

mkdir "$work/unpacked"
if [ "$archive" = "zip" ]; then
  if command -v unzip >/dev/null 2>&1; then
    unzip -q "$work/$filename" -d "$work/unpacked"
  elif command -v powershell.exe >/dev/null 2>&1; then
    powershell.exe -NoProfile -NonInteractive -Command \
      "Expand-Archive -LiteralPath '$(native_path "$work/$filename")' -DestinationPath '$(native_path "$work/unpacked")'"
  else
    fail "unzip or PowerShell is required to unpack $filename"
  fi
else
  require_cmd tar
  tar -xzf "$work/$filename" -C "$work/unpacked"
fi
[ -f "$work/unpacked/$binary" ] || fail "$filename did not contain $binary"

if [ -n "${SETUP_WHK_INSTALL_DIR:-}" ]; then
  install_dir="$(shell_path "$SETUP_WHK_INSTALL_DIR")"
elif [ -n "${RUNNER_TEMP:-}" ]; then
  install_dir="$(shell_path "$RUNNER_TEMP")/setup-whk/bin"
else
  fail "RUNNER_TEMP is not set; this script is meant to run as a GitHub Actions step."
fi
mkdir -p "$install_dir"
mv -f "$work/unpacked/$binary" "$install_dir/$binary"
chmod +x "$install_dir/$binary"

# Run it once: a binary that cannot start here fails now, with the reason,
# and not in a later step. Only what it prints counts as its version: on a
# glibc older than the build's, the loader adds a warning on stderr.
if reported="$("$install_dir/$binary" --version 2>"$work/version.err")"; then
  echo "$reported installed to $install_dir/$binary"
else
  reason="$(tr '\n' ' ' <"$work/version.err")"
  hint=""
  if [ "$os" = "linux" ]; then
    hint=" The Linux builds need glibc 2.34 or later (Ubuntu 22.04, Debian 12); they do not run on Alpine."
  fi
  fail "whk $version was installed but does not run on this runner: ${reason}${hint}"
fi

# --- Hand over to the steps that follow ---------------------------------------

if [ -n "${GITHUB_PATH:-}" ]; then
  native_path "$install_dir" >>"$GITHUB_PATH"
fi

if [ -n "${GITHUB_OUTPUT:-}" ]; then
  {
    echo "version=$version"
    echo "path=$(native_path "$install_dir/$binary")"
  } >>"$GITHUB_OUTPUT"
fi

if [ -n "$api_key" ]; then
  if [ -n "${GITHUB_ENV:-}" ]; then
    {
      echo "WHK_API_KEY=$api_key"
      echo "WHK_AUTH=key"
    } >>"$GITHUB_ENV"
  fi
  echo "WHK_API_KEY and WHK_AUTH=key are set for the steps that follow."
fi
