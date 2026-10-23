#!/usr/bin/env bash
# One-line runner for emby-tune. Nothing is installed permanently except Ruby itself
# (if it's missing and you agree): a snapshot of the repo is downloaded to a temp dir, run, and deleted.
#
#   curl -fsSL https://raw.githubusercontent.com/patrickemuller/deluge-and-emby-media-server/main/install.sh | bash
#   curl -fsSL https://raw.githubusercontent.com/patrickemuller/deluge-and-emby-media-server/main/install.sh | bash -s -- --host 192.168.1.50 --dry-run
#
# Everything after `--` is passed to emby-tune (see `emby-tune.rb --help`).
# --host is your Emby server's internal IP (run `hostname -I` on it); without it you are asked.
set -euo pipefail

TARBALL="${EMBY_TUNE_TARBALL:-https://codeload.github.com/patrickemuller/deluge-and-emby-media-server/tar.gz/refs/heads/main}"
SOURCE_DIR="${EMBY_TUNE_SOURCE:-}" # a local checkout to run instead of downloading (for development)

# Prompts must read the terminal: when piped into bash, stdin is this script.
tty_ok() { [ -t 0 ] || (exec </dev/tty) 2>/dev/null; }

ruby_ok() { command -v ruby >/dev/null 2>&1 && ruby -e 'exit(Gem::Version.new(RUBY_VERSION) >= Gem::Version.new("2.7") ? 0 : 1)'; }

if ! ruby_ok; then
  echo "emby-tune is written in Ruby 2.7+, which is not installed here."
  if command -v apt-get >/dev/null 2>&1; then
    answer=""
    case " $* " in *" -y "*|*" --yes "*) answer=y ;; esac
    if [ -z "$answer" ] && tty_ok; then
      read -r -p "Install it now with 'sudo apt-get install -y ruby'? [y/N] " answer </dev/tty || answer=""
    fi
    case "$answer" in
      y|Y|yes) sudo apt-get update -qq && sudo apt-get install -y ruby ;;
      *) echo "Install Ruby (sudo apt-get install ruby) and run this again." >&2; exit 1 ;;
    esac
  else
    echo "Install Ruby 2.7+ (https://www.ruby-lang.org/en/documentation/installation/) and run this again." >&2
    exit 1
  fi
fi
command -v curl >/dev/null 2>&1 || { echo "emby-tune needs curl" >&2; exit 1; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
if [ -n "$SOURCE_DIR" ]; then
  cp -R "$SOURCE_DIR/emby-tune.rb" "$SOURCE_DIR/lib" "$tmp/"
else
  curl -fsSL "$TARBALL" | tar -xz -C "$tmp" --strip-components=1
fi

if [ ! -t 0 ] && tty_ok; then
  ruby "$tmp/emby-tune.rb" "$@" </dev/tty
else
  ruby "$tmp/emby-tune.rb" "$@"
fi
