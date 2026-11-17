#!/usr/bin/env bash
# Smoke test for packaging/linux/AppRun: the AppImage's desktop integration writes
# and refreshes the host .desktop entry and icons, is idempotent, honours the opt-out
# and an unwritable HOME, and always launches the app.
#
# Runs in seconds with no build (CI: .github/workflows/packaging-lint.yml).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
APP_ID=ai.storyteller.craft-anything

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Fake AppDir with the real AppRun, .desktop template, icons, and a stub binary.
APPDIR="$TMP/Craft Anything.AppDir"
mkdir -p "$APPDIR/usr/bin"
install -Dm755 "$HERE/AppRun" "$APPDIR/AppRun"
install -Dm644 "$HERE/$APP_ID.desktop" "$APPDIR/usr/share/applications/$APP_ID.desktop"
mkdir -p "$APPDIR/usr/share/icons"
cp -R "$ROOT/assets/app-icon/hicolor" "$APPDIR/usr/share/icons/"
printf '#!/bin/sh\necho "stub: $*"\n' >"$APPDIR/usr/bin/craft-anything"
chmod +x "$APPDIR/usr/bin/craft-anything"
printf '#!/bin/sh\necho "cli: $*"\n' >"$APPDIR/usr/bin/craft-anything-cli"
chmod +x "$APPDIR/usr/bin/craft-anything-cli"

APPIMAGE="$TMP/craft-anything test.AppImage" # spaces on purpose: Exec must stay quoted
: >"$APPIMAGE"
export APPIMAGE
export HOME="$TMP/home"
export XDG_DATA_HOME="$HOME/.local/share"
mkdir -p "$HOME"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

# 1. Launch works and passes arguments through.
out="$("$APPDIR/AppRun" open file.png)" || fail "AppRun exited non-zero"
[[ "$out" = "stub: open file.png" ]] || fail "arguments not forwarded: $out"

DESKTOP="$XDG_DATA_HOME/applications/$APP_ID.desktop"
[[ -f "$DESKTOP" ]] || fail "desktop entry not installed"

# 2. Exec rewritten to the AppImage (quoted, spaces intact), TryExec dropped,
#    everything else preserved from the packaged entry.
expected_exec="Exec=\"$(readlink -f "$APPIMAGE")\" %F"
grep -Fxq "$expected_exec" "$DESKTOP" || fail "Exec not rewritten: $(grep '^Exec=' "$DESKTOP")"
grep -q '^TryExec=' "$DESKTOP" && fail "TryExec kept, the entry would be hidden"
grep -Fxq "Icon=$APP_ID" "$DESKTOP" || fail "Icon line lost"
grep -Fxq 'Categories=Development;Debugger;' "$DESKTOP" || fail "metadata lines lost"
if command -v desktop-file-validate >/dev/null; then
  desktop-file-validate "$DESKTOP" || fail "generated desktop entry is invalid"
fi

# 3. Icons landed under the name the .desktop entry references.
for f in "16x16/apps/$APP_ID.png" "256x256/apps/$APP_ID.png" "scalable/apps/$APP_ID.svg"; do
  [[ -f "$XDG_DATA_HOME/icons/hicolor/$f" ]] || fail "icon missing: $f"
done

# 4. Idempotent: a second launch must not rewrite anything (inode unchanged).
before="$(stat -c %i "$DESKTOP")"
out="$("$APPDIR/AppRun")" || fail "second launch exited non-zero"
[[ "$out" = "stub: " ]] || fail "second launch output: $out"
after="$(stat -c %i "$DESKTOP")"
[[ "$before" = "$after" ]] || fail "desktop entry rewritten although unchanged"

# 5. Moving the AppImage refreshes Exec.
mv "$APPIMAGE" "$TMP/moved.AppImage"
export APPIMAGE="$TMP/moved.AppImage"
"$APPDIR/AppRun" >/dev/null || fail "launch after move exited non-zero"
grep -Fxq "Exec=\"$(readlink -f "$APPIMAGE")\" %F" "$DESKTOP" || fail "Exec not refreshed after move"

# 6. Opt-out installs nothing.
rm -rf "$XDG_DATA_HOME"
CRAFT_ANYTHING_NO_DESKTOP_INTEGRATION=1 "$APPDIR/AppRun" >/dev/null || fail "opt-out launch exited non-zero"
[[ ! -e "$XDG_DATA_HOME" ]] || fail "opt-out still integrated"

# 7. An unwritable data dir never blocks the launch.
mkdir -p "$TMP/ro" && chmod a-w "$TMP/ro"
out="$(XDG_DATA_HOME="$TMP/ro/data" "$APPDIR/AppRun" out.txt)" || fail "launch blocked by unwritable data dir"
[[ "$out" = "stub: out.txt" ]] || fail "stub not run against unwritable data dir: $out"
chmod u+w "$TMP/ro"

# 8. No $APPIMAGE (extracted AppDir): launch only, nothing installed.
rm -rf "$XDG_DATA_HOME"
env -u APPIMAGE "$APPDIR/AppRun" >/dev/null || fail "extracted-AppDir launch exited non-zero"
[[ ! -e "$XDG_DATA_HOME" ]] || fail "integrated without $APPIMAGE"

# 9. A path that would need Exec escaping (here a `$`): launch only, nothing installed.
rm -rf "$XDG_DATA_HOME"
odd="$TMP/odd\$(id).AppImage"
: >"$odd"
out="$(APPIMAGE="$odd" "$APPDIR/AppRun" x)" || fail "launch with an odd path exited non-zero"
[[ "$out" = "stub: x" ]] || fail "odd path: $out"
[[ ! -e "$XDG_DATA_HOME" ]] || fail "integrated an AppImage path that needs escaping"

# 10. `--cli` runs the bundled CLI with the rest of the arguments, and integrates nothing (#723).
rm -rf "$XDG_DATA_HOME"
out="$("$APPDIR/AppRun" --cli mcp --project "a b.cany")" || fail "--cli exited non-zero"
[[ "$out" = "cli: mcp --project a b.cany" ]] || fail "--cli not routed to the CLI: $out"
[[ ! -e "$XDG_DATA_HOME" ]] || fail "a CLI run integrated the desktop entry"

# 11. Started through a link named craft-anything-cli ($ARGV0), every argument goes to the CLI.
out="$(ARGV0="/home/u/.local/bin/craft-anything-cli" "$APPDIR/AppRun" --version)" || fail "ARGV0 route exited non-zero"
[[ "$out" = "cli: --version" ]] || fail "ARGV0 not routed to the CLI: $out"
[[ ! -e "$XDG_DATA_HOME" ]] || fail "an ARGV0 CLI run integrated the desktop entry"

# 12. Any other name, or --cli later on the line, still starts the app.
out="$(ARGV0="craft-anything" "$APPDIR/AppRun" open --cli)" || fail "app launch exited non-zero"
[[ "$out" = "stub: open --cli" ]] || fail "app launch routed to the CLI: $out"

# 13-22. An icon cache another app left in hicolor (#1877). Stand-in cache tools on PATH
# record their calls, so this runs the same with or without GTK installed. GTK compares
# whole seconds, so the checks below do too (seconds).
ICONS="$XDG_DATA_HOME/icons/hicolor"
CACHE="$ICONS/icon-theme.cache"
TOOLS="$TMP/tools"
CALLS="$TMP/cache-calls"
mkdir -p "$TOOLS"
for t in gtk-update-icon-cache gtk4-update-icon-cache; do
  # shellcheck disable=SC2016 # $* and $4 belong to the stand-in, not to this script
  # Like the real tools: write the cache, then date the folder at the cache's whole second.
  printf '#!/bin/sh\necho "%s $*" >>"%s"\n[ -n "${CACHE_TOOL_FAILS:-}" ] && exit 1\n: >"$4/icon-theme.cache"\ntouch -d "@$(stat -c %%Y "$4/icon-theme.cache")" "$4"\n' \
    "$t" "$CALLS" >"$TOOLS/$t"
  chmod +x "$TOOLS/$t"
done
seconds() { stat -c %Y "$1"; }
other_app_cache() { # the other app's icons in every size folder ours uses, then its cache
  rm -rf "$XDG_DATA_HOME" "$CALLS"
  (cd "$APPDIR/usr/share/icons/hicolor" && find . -type d) | while IFS= read -r d; do
    mkdir -p "$ICONS/$d"
  done
  : >"$ICONS/scalable/apps/other-app.svg"
  : >"$CACHE"
  touch -d '-2 minutes' "$ICONS"
  touch -d '-1 minute' "$CACHE"
}

# 13. Icons copied under a cache: the cache is rebuilt, once, for the theme folder.
other_app_cache
PATH="$TOOLS:$PATH" "$APPDIR/AppRun" >/dev/null || fail "launch with a stale cache exited non-zero"
[[ "$(cat "$CALLS")" = "gtk-update-icon-cache -f -t -q $ICONS" ]] || fail "cache not rebuilt: $(cat "$CALLS" 2>/dev/null)"

# 14. Nothing copied (a second launch): the cache is left alone.
rm -f "$CALLS"
PATH="$TOOLS:$PATH" "$APPDIR/AppRun" >/dev/null || fail "second launch with a cache exited non-zero"
[[ ! -e "$CALLS" ]] || fail "cache rebuilt although no icon changed: $(cat "$CALLS")"

# 15. The tools fail (or aren't there): the theme folder is made newer than the cache, so
#     the stale cache isn't trusted, and the app still starts.
other_app_cache
out="$(CACHE_TOOL_FAILS=1 PATH="$TOOLS:$PATH" "$APPDIR/AppRun" y)" || fail "launch with failing cache tools exited non-zero"
[[ "$out" = "stub: y" ]] || fail "failing cache tools: $out"
[[ "$(seconds "$ICONS")" -gt "$(seconds "$CACHE")" ]] || fail "stale cache not older than the theme folder"
rm -f "$CALLS"
CACHE_TOOL_FAILS=1 PATH="$TOOLS:$PATH" "$APPDIR/AppRun" >/dev/null || fail "next launch with failing cache tools exited non-zero"
[[ ! -e "$CALLS" ]] || fail "cache tools tried again although the cache is already out of date"

# 16. Our icons were installed by an earlier launch (an AppRun without this fix) under the
#     other app's cache: nothing is copied now, but the cache is still rebuilt.
other_app_cache
(cd "$APPDIR/usr/share/icons/hicolor" && find . -type f) | while IFS= read -r rel; do
  cp "$APPDIR/usr/share/icons/hicolor/$rel" "$ICONS/$rel"
done
touch -d '-2 minutes' "$ICONS"
PATH="$TOOLS:$PATH" "$APPDIR/AppRun" >/dev/null || fail "launch over installed icons exited non-zero"
[[ "$(cat "$CALLS" 2>/dev/null)" = "gtk-update-icon-cache -f -t -q $ICONS" ]] || fail "cache over already-installed icons not rebuilt"

# 17. An installed icon dated in the future (a clock that was ahead): rebuilt once, not on
#     every launch.
other_app_cache
PATH="$TOOLS:$PATH" "$APPDIR/AppRun" >/dev/null || fail "launch before the future-dated icon exited non-zero"
touch -d '+1 hour' "$ICONS/scalable/apps/$APP_ID.svg"
rm -f "$CALLS"
PATH="$TOOLS:$PATH" "$APPDIR/AppRun" >/dev/null || fail "launch with a future-dated icon exited non-zero"
PATH="$TOOLS:$PATH" "$APPDIR/AppRun" >/dev/null || fail "next launch with a future-dated icon exited non-zero"
[[ "$(wc -l <"$CALLS")" -eq 1 ]] || fail "cache rebuilt on every launch for a future-dated icon: $(cat "$CALLS")"

# 18. A theme folder we can't write: the tools aren't tried (they'd fail on every launch).
#     Root can write anywhere, so this is checked only when not running as root.
if [[ "$(id -u)" != 0 ]]; then
  other_app_cache
  chmod a-w "$ICONS"
  PATH="$TOOLS:$PATH" "$APPDIR/AppRun" >/dev/null || fail "launch with an unwritable theme folder exited non-zero"
  chmod u+w "$ICONS"
  [[ ! -e "$CALLS" ]] || fail "cache tools run on an unwritable theme folder: $(cat "$CALLS")"
fi

# 19. The folder changed in the same second as the cache was made (a size folder added
#     right after): GTK still trusts the cache, so it is rebuilt.
other_app_cache
s0=$(($(date +%s) - 60))
touch -d "@$s0.2" "$CACHE"
touch -d "@$s0.7" "$ICONS"
PATH="$TOOLS:$PATH" "$APPDIR/AppRun" >/dev/null || fail "launch with a same-second cache exited non-zero"
[[ -e "$CALLS" ]] || fail "cache made in the folder's second not rebuilt"

# 20. A cache dated in the future (another app's clock was ahead), our icons already in
#     place: rebuilt once.
other_app_cache
PATH="$TOOLS:$PATH" "$APPDIR/AppRun" >/dev/null || fail "launch before the future-dated cache exited non-zero"
touch -d '+1 hour' "$CACHE"
rm -f "$CALLS"
PATH="$TOOLS:$PATH" "$APPDIR/AppRun" >/dev/null || fail "launch with a future-dated cache exited non-zero"
PATH="$TOOLS:$PATH" "$APPDIR/AppRun" >/dev/null || fail "next launch with a future-dated cache exited non-zero"
[[ "$(wc -l <"$CALLS" 2>/dev/null)" -eq 1 ]] || fail "future-dated cache not rebuilt exactly once: $(cat "$CALLS" 2>/dev/null)"

# 21. hicolor is a link to the real folder (a dotfile manager), the link newer than the
#     cache: judged by the folder, as GTK does, so the stale cache is rebuilt.
other_app_cache
mv "$ICONS" "$TMP/hicolor-real"
ln -s "$TMP/hicolor-real" "$ICONS"
touch -h -d '-30 seconds' "$ICONS"
PATH="$TOOLS:$PATH" "$APPDIR/AppRun" >/dev/null || fail "launch with a linked theme folder exited non-zero"
[[ -e "$CALLS" ]] || fail "stale cache behind a linked theme folder not rebuilt"
rm -f "$ICONS"
rm -rf "$TMP/hicolor-real"

# 22. No cache to begin with: none is made.
rm -rf "$XDG_DATA_HOME" "$CALLS"
PATH="$TOOLS:$PATH" "$APPDIR/AppRun" >/dev/null || fail "launch without a cache exited non-zero"
[[ ! -e "$CALLS" && ! -e "$CACHE" ]] || fail "a cache was made where there was none"

echo "AppRun desktop integration and CLI routing ok"
