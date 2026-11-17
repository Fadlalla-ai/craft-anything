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

# 13-20. An icon cache another app left in hicolor (#1877). Stand-in cache tools on PATH
# record their calls, so this runs the same with or without GTK installed.
ICONS="$XDG_DATA_HOME/icons/hicolor"
CACHE="$ICONS/icon-theme.cache"
STAMP="$XDG_DATA_HOME/$APP_ID/icon-cache.stamp"
TOOLS="$TMP/tools"
CALLS="$TMP/cache-calls"
mkdir -p "$TOOLS"
for t in gtk-update-icon-cache gtk4-update-icon-cache; do
  # shellcheck disable=SC2016 # $* and $4 belong to the stand-in, not to this script
  printf '#!/bin/sh\necho "%s $*" >>"%s"\n[ -n "${CACHE_TOOL_FAILS:-}" ] && exit 1\necho rebuilt >"$4/icon-theme.cache"\n' \
    "$t" "$CALLS" >"$TOOLS/$t"
  chmod +x "$TOOLS/$t"
done
launch() { PATH="$TOOLS:$PATH" "$APPDIR/AppRun" "$@"; }
calls() { if [[ -e "$CALLS" ]]; then wc -l <"$CALLS"; else echo 0; fi; }
other_app_cache() { # the other app's icons in every size folder ours uses, then its cache
  rm -rf "$XDG_DATA_HOME" "$CALLS"
  (cd "$APPDIR/usr/share/icons/hicolor" && find . -type d) | while IFS= read -r d; do
    mkdir -p "$ICONS/$d"
  done
  : >"$ICONS/scalable/apps/other-app.svg"
  echo "other app" >"$CACHE"
  touch -d '-2 minutes' "$ICONS"
  touch -d '-1 minute' "$CACHE"
}

# 13. Icons copied under another app's cache: it is rebuilt, for the theme folder, and the
#     stamp records it; the next launches leave it alone.
other_app_cache
launch >/dev/null || fail "launch with a stale cache exited non-zero"
[[ "$(cat "$CALLS" 2>/dev/null)" = "gtk-update-icon-cache -f -t -q $ICONS" ]] || fail "cache not rebuilt: $(cat "$CALLS" 2>/dev/null)"
[[ -s "$STAMP" ]] || fail "no stamp after the rebuild"
launch >/dev/null || fail "later launches exited non-zero"
launch >/dev/null || fail "later launches exited non-zero (second time)"
[[ "$(calls)" = 1 ]] || fail "cache rebuilt again although nothing changed: $(cat "$CALLS")"

# 14. Our icons were installed by an AppRun without this (no stamp) under the other app's
#     cache: nothing is copied now, but the cache is rebuilt once.
other_app_cache
cp -R "$APPDIR/usr/share/icons/hicolor/." "$ICONS/"
launch >/dev/null || fail "launch over installed icons exited non-zero"
launch >/dev/null || fail "launch over installed icons exited non-zero (second time)"
[[ "$(calls)" = 1 ]] || fail "cache over already-installed icons not rebuilt exactly once: $(cat "$CALLS" 2>/dev/null)"

# 15. Our icons changed in an update (the stamp is for older ones): rebuilt once more.
rm -f "$CALLS"
echo "an older version's icons" >"$STAMP"
launch >/dev/null || fail "launch after an icon update exited non-zero"
launch >/dev/null || fail "launch after an icon update exited non-zero (second time)"
[[ "$(calls)" = 1 ]] || fail "cache not rebuilt exactly once for changed icons: $(cat "$CALLS" 2>/dev/null)"

# 16. An icon copied again (someone removed it), stamp current: rebuilt, so the cache has it.
rm -f "$CALLS" "$ICONS/256x256/apps/$APP_ID.png"
launch >/dev/null || fail "launch after an icon was removed exited non-zero"
[[ "$(calls)" = 1 ]] || fail "cache not rebuilt after an icon was copied again"

# 17. The tools fail (or aren't there): the theme folder is made newer than the cache, so
#     GTK reads the folders instead; tried once, not on every launch; the app still starts.
other_app_cache
out="$(CACHE_TOOL_FAILS=1 launch y)" || fail "launch with failing cache tools exited non-zero"
[[ "$out" = "stub: y" ]] || fail "failing cache tools: $out"
[[ "$ICONS" -nt "$CACHE" ]] || fail "stale cache not older than the theme folder"
CACHE_TOOL_FAILS=1 launch >/dev/null || fail "next launch with failing cache tools exited non-zero"
[[ "$(calls)" = 2 ]] || fail "cache tools tried again on a later launch: $(cat "$CALLS")"

# 18. A theme folder we can't write (made by root, say): nothing to mend, tried once, and
#     the launch goes ahead. Root can write anywhere, so checked only when not root.
if [[ "$(id -u)" != 0 ]]; then
  other_app_cache
  cp -R "$APPDIR/usr/share/icons/hicolor/." "$ICONS/"
  chmod -R a-w "$ICONS"
  ok=1
  CACHE_TOOL_FAILS=1 launch >/dev/null && CACHE_TOOL_FAILS=1 launch >/dev/null || ok=
  chmod -R u+w "$ICONS"
  [[ -n "$ok" ]] || fail "launch with an unwritable theme folder exited non-zero"
  [[ "$(calls)" = 2 ]] || fail "cache tools tried on every launch for an unwritable folder: $(cat "$CALLS")"
fi

# 19. hicolor is a link to the real folder (a dotfile manager): handled as a folder.
other_app_cache
mv "$ICONS" "$TMP/hicolor-real"
ln -s "$TMP/hicolor-real" "$ICONS"
launch >/dev/null || fail "launch with a linked theme folder exited non-zero"
[[ "$(cat "$TMP/hicolor-real/icon-theme.cache")" = rebuilt ]] || fail "cache behind a linked theme folder not rebuilt"
rm -f "$ICONS"
rm -rf "$TMP/hicolor-real"

# 20. No cache to begin with: none is made, and nothing is run.
rm -rf "$XDG_DATA_HOME" "$CALLS"
launch >/dev/null || fail "launch without a cache exited non-zero"
[[ ! -e "$CALLS" && ! -e "$CACHE" ]] || fail "a cache was made where there was none"

echo "AppRun desktop integration and CLI routing ok"
