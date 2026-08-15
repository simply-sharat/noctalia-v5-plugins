#!/usr/bin/env bash
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

SOURCE_NAME=""
SOURCE_TYPE="path"
URL=""
LINT=0
DRY_RUN=0

usage() {
  cat <<'EOF'
Usage: install.sh [options]

Install every plugin in this repository into the running Noctalia shell.
Plugins are discovered by scanning for plugin.toml files, so any plugin added
to the repo in the future is picked up automatically.

Options:
  -n, --source NAME    Name for the plugin source (default: repo basename)
  -u, --url URL        Register the repo as a git source at URL instead of a
                       local path source
  -t, --type TYPE      Source type: path or git (default: path; git with --url)
  -l, --lint           Run 'noctalia plugins lint' on each plugin first
      --dry-run        Print what would be done without changing anything
  -h, --help           Show this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -n|--source) SOURCE_NAME="${2:?--source needs a name}"; shift 2;;
    -u|--url) URL="${2:?--url needs a URL}"; shift 2;;
    -t|--type) SOURCE_TYPE="${2:?--type needs path or git}"; shift 2;;
    -l|--lint) LINT=1; shift;;
    --dry-run) DRY_RUN=1; shift;;
    -h|--help) usage; exit 0;;
    *) echo "error: unknown option: $1" >&2; usage; exit 1;;
  esac
done

if [[ "$SOURCE_TYPE" != "path" && "$SOURCE_TYPE" != "git" ]]; then
  echo "error: --type must be path or git" >&2
  exit 1
fi

if [[ -n "$URL" ]]; then
  LOCATION="$URL"
  if [[ "$SOURCE_TYPE" == "path" ]]; then
    SOURCE_TYPE="git"
  fi
else
  LOCATION="$REPO"
  if [[ "$SOURCE_TYPE" == "git" ]]; then
    echo "error: --type git needs --url (or omit --type for a local path source)" >&2
    exit 1
  fi
fi

if [[ -z "$SOURCE_NAME" ]]; then
  SOURCE_NAME="$(basename "$REPO")"
fi

plugins=()
while IFS= read -r -d '' toml; do
  dir="$(dirname "$toml")"
  id="$(sed -n 's/^[[:space:]]*id[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' "$toml" | head -n1)"
  if [[ -n "$id" ]]; then
    plugins+=("$id|$dir")
  fi
done < <(find "$REPO" -maxdepth 2 -name plugin.toml -not -path '*/.git/*' -print0 | sort -z)

if [[ ${#plugins[@]} -eq 0 ]]; then
  echo "error: no plugins found under $REPO" >&2
  exit 1
fi

echo "Found ${#plugins[@]} plugin(s) in $REPO:"
for entry in "${plugins[@]}"; do
  id="${entry%%|*}"
  dir="${entry#*|}"
  entries="$(awk '
    /^\[\[(widget|panel|service|shortcut|desktop_widget)\]\]/ { header=$0 }
    /^[[:space:]]*id[[:space:]]*=[[:space:]]*"/ {
      if (header != "") {
        line=$0
        sub(/^[[:space:]]*id[[:space:]]*=[[:space:]]*"/, "", line)
        sub(/".*/, "", line)
        print "  " header " id \"" line "\""
        header=""
      }
    }
  ' "$dir/plugin.toml")"
  printf '  %s  [%s]\n' "$id" "$(basename "$dir")"
  if [[ -n "$entries" ]]; then
    echo "$entries"
  fi
done
echo

if (( DRY_RUN )); then
  echo "[dry-run] nothing will be changed"
else
  if ! noctalia msg plugins list >/dev/null 2>&1; then
    echo "error: Noctalia does not appear to be running (noctalia msg failed); start it first" >&2
    exit 1
  fi
fi

register_source() {
  local existing line name rest stype loc want found=""
  existing="$(noctalia msg plugins source list 2>/dev/null || true)"
  while IFS= read -r line; do
    if [[ -z "$line" ]]; then
      continue
    fi
    name="${line%% *}"
    rest="${line#* }"
    stype="${rest%% *}"
    loc="${rest#* }"
    if [[ "$stype" == "$SOURCE_TYPE" ]]; then
      want="$LOCATION"
      if [[ "$SOURCE_TYPE" == "path" ]]; then
        loc="$(realpath "$loc" 2>/dev/null || echo "$loc")"
        want="$(realpath "$want" 2>/dev/null || echo "$want")"
      fi
      if [[ "$loc" == "$want" ]]; then
        found="$name"
        break
      fi
    fi
  done <<< "$existing"

  if [[ -n "$found" ]]; then
    echo "-> source '$found' already registered, reusing it"
    SOURCE_NAME="$found"
    return 0
  fi

  while IFS= read -r line; do
    if [[ -z "$line" ]]; then
      continue
    fi
    name="${line%% *}"
    if [[ "$name" == "$SOURCE_NAME" ]]; then
      echo "error: source '$SOURCE_NAME' exists with a different location; re-run with --source <newname>" >&2
      return 1
    fi
  done <<< "$existing"

  if (( DRY_RUN )); then
    echo "-> would run: noctalia msg plugins source add \"$SOURCE_NAME\" \"$SOURCE_TYPE\" \"$LOCATION\""
  else
    noctalia msg plugins source add "$SOURCE_NAME" "$SOURCE_TYPE" "$LOCATION"
  fi
}

echo "== Source =="
register_source
echo "source: $SOURCE_NAME ($SOURCE_TYPE $LOCATION)"

if (( LINT )); then
  echo "== Lint =="
  for entry in "${plugins[@]}"; do
    dir="${entry#*|}"
    if (( DRY_RUN )); then
      echo "-> would run: noctalia plugins lint \"$dir\""
    else
      if ! noctalia plugins lint "$dir"; then
        echo "error: lint failed for $dir; fix it and re-run (or drop --lint)" >&2
        exit 1
      fi
    fi
  done
fi

echo "== Enable =="
for entry in "${plugins[@]}"; do
  id="${entry%%|*}"
  if (( DRY_RUN )); then
    echo "-> would run: noctalia msg plugins enable \"$id\""
  else
    if ! noctalia msg plugins enable "$id"; then
      echo "  warning: failed to enable $id" >&2
    fi
  fi
done

echo
echo "Done. ${#plugins[@]} plugin(s) enabled from source '$SOURCE_NAME'."
cat <<'EOF'

Next: add the widgets you want to the bar in ~/.config/noctalia/config.toml, e.g.

  [widget.budslink]
  type = "simply-sharat/budslink:bar"

add "budslink" to the [bar.default] start/end list, then run
  noctalia msg config-reload
EOF
