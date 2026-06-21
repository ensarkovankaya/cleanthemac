#!/usr/bin/env zsh
#
# clean.sh — safe developer cache cleaner (macOS)
#
# Flow: analyze -> report -> ask per category -> delete only what you approve.
# Prefers each tool's native cleanup command (docker/go/npm/uv/pnpm/brew);
# otherwise removes only known cache paths with rm -rf.
#
# Targets ONLY recreatable cache data. Real data — iCloud, project source,
# browser profiles — is NEVER touched.
#
# Usage:
#   ./clean.sh                 interactive (analyze + report + approve + delete)
#   ./clean.sh --dry-run       report only; deletes nothing
#   ./clean.sh --yes           delete all available categories, no prompt (volumes excluded)
#   ./clean.sh --only docker,npm   restrict to the listed categories
#   ./clean.sh --docker-volumes    also prune Docker named volumes (RISKY)
#   ./clean.sh --help

emulate -L zsh
setopt no_unset pipe_fail

# ----------------------------------------------------------------- colors ----
if [[ -t 1 ]]; then
  C_RST=$'\e[0m'; C_DIM=$'\e[2m'; C_B=$'\e[1m'
  C_GRN=$'\e[32m'; C_YEL=$'\e[33m'; C_RED=$'\e[31m'; C_CYN=$'\e[36m'
else
  C_RST=''; C_DIM=''; C_B=''; C_GRN=''; C_YEL=''; C_RED=''; C_CYN=''
fi

# ------------------------------------------------------------------ flags ----
DRY_RUN=0
ASSUME_YES=0
DOCKER_VOLUMES=0
ONLY=""

while (( $# )); do
  case "$1" in
    --dry-run)        DRY_RUN=1 ;;
    --yes|-y)         ASSUME_YES=1 ;;
    --docker-volumes) DOCKER_VOLUMES=1 ;;
    --only)           shift; ONLY="${1:-}" ;;
    --only=*)         ONLY="${1#--only=}" ;;
    --help|-h)        sed -n '3,18p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) print -ru2 -- "${C_RED}Unknown argument: $1${C_RST}"; exit 2 ;;
  esac
  shift
done

# ---------------------------------------------------------------- helpers ----
have() { command -v "$1" >/dev/null 2>&1; }

# kilobytes -> human readable
human() {
  local kb=$1
  if   (( kb >= 1048576 )); then printf '%.1fG' "$(( kb / 1048576.0 ))"
  elif (( kb >= 1024 ));    then printf '%.0fM' "$(( kb / 1024.0 ))"
  else printf '%dK' "$kb"
  fi
}

# total size (KB) of one or more paths; 0 if none exist
path_kb() {
  local total=0 p="" sz=""
  for p in "$@"; do
    [[ -e "$p" ]] || continue
    sz=$(/usr/bin/du -sk "$p" 2>/dev/null | awk '{print $1}')
    [[ -n "$sz" ]] && (( total += sz ))
  done
  print -- "$total"
}

# free space on the root disk (KB)
disk_free_kb() { /bin/df -k / | awk 'NR==2{print $4}'; }

# ask yes/no (default: no)
confirm() {
  local prompt="$1" reply=""
  (( ASSUME_YES )) && return 0
  read "reply?$prompt [y/N]: "
  [[ "$reply" == (y|Y|yes|e|E|evet) ]]
}

# --------------------------------------------------------------- registry ----
typeset -A LABEL DESC SAFETY KIND TARGETS SIZE_KB AVAIL NOTE
typeset -a ORDER

# register <key> <kind:path|tool> <label> <safety:safe|caution> <desc>
register() {
  local k=$1
  ORDER+=("$k")
  KIND[$k]=$2; LABEL[$k]=$3; SAFETY[$k]=$4; DESC[$k]=$5
  AVAIL[$k]=0; SIZE_KB[$k]=0; NOTE[$k]=""; TARGETS[$k]=""
}

H="$HOME"

register docker     tool "Docker (images/containers/build cache)" caution \
  "Unused images, stopped containers, and build cache."
register claude_vm  path "Claude local-agent VM bundles"          caution \
  "Local agent mode VM images. Re-downloaded if removed."
TARGETS[claude_vm]="$H/Library/Application Support/Claude/vm_bundles"

register go_modcache tool "Go module cache"                       safe \
  "Downloaded Go modules. Re-fetched on next build."
TARGETS[go_modcache]="$H/go/pkg/mod"

register npm        tool "npm cache"                              safe \
  "npm package cache (_cacache). Re-downloaded."
TARGETS[npm]="$H/.npm/_cacache"

register uv         tool "uv cache"                               safe \
  "Python (uv) package cache. Unused entries are pruned."
TARGETS[uv]="$H/.cache/uv"

register pnpm       tool "pnpm store"                             safe \
  "pnpm global content store. Unreferenced packages are pruned."

register playwright path "Playwright browser binaries"            safe \
  "Downloaded browsers. Re-downloaded on next use."
TARGETS[playwright]="$H/Library/Caches/ms-playwright"

register codex      path "codex-runtimes cache"                   safe \
  "Codex runtime download cache."
TARGETS[codex]="$H/.cache/codex-runtimes"

register copilot    path "github-copilot cache"                   safe \
  "GitHub Copilot cache."
TARGETS[copilot]="$H/.cache/github-copilot"

register brew       tool "Homebrew download cache"                safe \
  "Downloaded formula/bottle archives."

register pip        tool "pip cache"                              safe \
  "Python pip wheel/download cache."

register misc       path "Other tool caches"                     safe \
  "golangci-lint, outlines, node, nvim caches."
TARGETS[misc]="$H/.cache/golangci-lint
$H/.cache/outlines
$H/.cache/node
$H/.cache/nvim"

# --only filter
if [[ -n "$ONLY" ]]; then
  local -a keep=("${(@s:,:)ONLY}") filtered=()
  for k in $ORDER; do
    [[ " ${keep[*]} " == *" $k "* ]] && filtered+=("$k")
  done
  ORDER=("${filtered[@]}")
  (( ${#ORDER} )) || { print -ru2 -- "${C_RED}No categories matched --only.${C_RST}"; exit 2; }
fi

# --------------------------------------------------------------- ANALYSIS ----
# Analyze a single category (in a function so local vars behave correctly)
analyze_key() {
  local k=$1 rec="" sp="" bc="" pc="" p=""
  local -a ps=()
  case "$k" in
    docker)
      if have docker && docker info >/dev/null 2>&1; then
        AVAIL[$k]=1
        SIZE_KB[$k]=$(path_kb "$H/Library/Containers/com.docker.docker/Data/vms")
        rec=$(docker system df --format '{{.Type}}: {{.Reclaimable}}' 2>/dev/null | paste -sd'; ' -)
        NOTE[$k]="reclaimable → ${rec}"
      else
        NOTE[$k]="docker daemon not running/reachable — skipped"
      fi
      ;;
    go_modcache)
      [[ -d "${TARGETS[$k]}" ]] && { AVAIL[$k]=1; SIZE_KB[$k]=$(path_kb "${TARGETS[$k]}"); }
      have go || NOTE[$k]="(go not installed; removed via chmod+rm)"
      ;;
    npm)
      [[ -d "${TARGETS[$k]}" ]] && { AVAIL[$k]=1; SIZE_KB[$k]=$(path_kb "${TARGETS[$k]}"); }
      ;;
    uv)
      if have uv && [[ -d "${TARGETS[$k]}" ]]; then
        AVAIL[$k]=1; SIZE_KB[$k]=$(path_kb "${TARGETS[$k]}")
        NOTE[$k]="prune only removes unused entries (not all)"
      fi
      ;;
    pnpm)
      if have pnpm; then
        sp=$(pnpm store path 2>/dev/null)
        if [[ -n "$sp" && -d "$sp" ]]; then
          AVAIL[$k]=1; SIZE_KB[$k]=$(path_kb "$sp"); TARGETS[$k]="$sp"
          NOTE[$k]="prune only removes unreferenced packages"
        fi
      fi
      ;;
    brew)
      if have brew; then
        bc=$(brew --cache 2>/dev/null)
        [[ -n "$bc" && -d "$bc" ]] && { AVAIL[$k]=1; SIZE_KB[$k]=$(path_kb "$bc"); TARGETS[$k]="$bc"; }
      fi
      ;;
    pip)
      pc="$H/Library/Caches/pip"
      [[ -d "$pc" ]] && { AVAIL[$k]=1; SIZE_KB[$k]=$(path_kb "$pc"); TARGETS[$k]="$pc"; }
      ;;
    *)  # path type
      ps=("${(@f)TARGETS[$k]}")
      for p in $ps; do [[ -e "$p" ]] && AVAIL[$k]=1; done
      (( AVAIL[$k] )) && SIZE_KB[$k]=$(path_kb "${ps[@]}")
      ;;
  esac
}

print -- "${C_B}${C_CYN}== Analyzing caches... ==${C_RST}"
for k in $ORDER; do analyze_key "$k"; done

# ----------------------------------------------------------------- REPORT ----
render_row() {
  local idx=$1 k=$2 tag="" color=""
  if [[ "${SAFETY[$k]}" == safe ]]; then tag="safe"; color="$C_GRN"
  else tag="caution"; color="$C_YEL"; fi
  printf "%-3s %-42s %8s  ${color}%s${C_RST}\n" "$idx." "${LABEL[$k]}" "$(human ${SIZE_KB[$k]})" "$tag"
  print -- "    ${C_DIM}${DESC[$k]}${C_RST}"
  [[ -n "${NOTE[$k]}" ]] && print -- "    ${C_DIM}↳ ${NOTE[$k]}${C_RST}"
}

print -- ""
box_bar=$(printf '═%.0s' {1..62})   # 62 box-drawing chars, width-matched to the content row
print -- "${C_B}╔${box_bar}╗${C_RST}"
printf  "${C_B}║%-62s║${C_RST}\n" "  CACHE CLEANUP REPORT"
print -- "${C_B}╚${box_bar}╝${C_RST}"

# sort by size, descending (available categories only)
typeset -a rows=()
total_kb=0
for k in $ORDER; do
  (( AVAIL[$k] )) || continue
  rows+=("${SIZE_KB[$k]}|$k")
  (( total_kb += SIZE_KB[$k] ))
done
typeset -a sorted=("${(@On)rows}")   # numeric, descending

if (( ${#sorted} == 0 )); then
  print -- "${C_YEL}No cleanable caches found.${C_RST}"
else
  printf "${C_DIM}%-3s %-42s %8s  %s${C_RST}\n" "#" "Category" "Size" "Safety"
  print -- "${C_DIM}─────────────────────────────────────────────────────────────────${C_RST}"
  i=0
  for row in $sorted; do
    i=$(( i + 1 ))
    render_row "$i" "${row#*|}"
  done
  print -- "${C_DIM}─────────────────────────────────────────────────────────────────${C_RST}"
  printf "${C_B}%-46s %8s${C_RST}\n" "TOTAL (upper bound)" "$(human $total_kb)"
fi

# briefly list skipped categories
typeset -a skipped=()
for k in $ORDER; do
  (( AVAIL[$k] )) && continue
  [[ -n "${NOTE[$k]}" ]] && skipped+=("${LABEL[$k]} — ${NOTE[$k]}")
done
(( ${#skipped} )) && { print -- ""; print -- "${C_DIM}Skipped: ${(j:; :)skipped}${C_RST}"; }

if (( DRY_RUN )); then
  print -- ""
  print -- "${C_CYN}--dry-run: nothing was deleted.${C_RST}"
  exit 0
fi
(( ${#sorted} )) || exit 0

# --------------------------------------------------------------- APPROVAL ----
print -- ""
print -- "${C_B}== Approval ==${C_RST} ${C_DIM}(default No; only 'y' confirms deletion)${C_RST}"

typeset -a approved=()
for row in $sorted; do
  k="${row#*|}"
  prompt="${C_B}${LABEL[$k]}${C_RST} (${C_CYN}$(human ${SIZE_KB[$k]})${C_RST}) — delete?"
  [[ "${SAFETY[$k]}" == caution ]] && prompt="${C_YEL}[caution]${C_RST} $prompt"
  confirm "$prompt" && approved+=("$k")
done

if (( ${#approved} == 0 )); then
  print -- ""; print -- "${C_YEL}No categories approved. Exiting.${C_RST}"; exit 0
fi

# ---------------------------------------------------------------- CLEANUP ----
clean_one() {
  local k=$1 lvl=2 lr="" p=""
  local -a ps=()
  case "$k" in
    docker)
      if (( ! ASSUME_YES )); then
        print -- ""
        print -- "  Select Docker level:"
        print -- "    ${C_DIM}1) dangling (dangling images + stopped containers)${C_RST}"
        print -- "    ${C_DIM}2) all unused images (volumes preserved) [recommended]${C_RST}"
        print -- "    ${C_DIM}3) + named volumes (RISKY: may delete DB data)${C_RST}"
        read "lr?  Choice [1/2/3, default 2]: "
        case "$lr" in 1) lvl=1;; 3) lvl=3;; *) lvl=2;; esac
      else
        (( DOCKER_VOLUMES )) && lvl=3 || lvl=2
      fi
      case "$lvl" in
        1) docker system prune -f ;;
        2) docker system prune -af ;;
        3) docker system prune -af --volumes ;;
      esac
      print -- "  ${C_GRN}✓ docker prune (level $lvl)${C_RST}"
      ;;
    go_modcache)
      if have go; then go clean -modcache
      else chmod -R u+w "${TARGETS[$k]}" 2>/dev/null; rm -rf "${TARGETS[$k]}"; fi
      print -- "${C_GRN}✓${C_RST}"
      ;;
    npm)
      if have npm; then npm cache clean --force >/dev/null 2>&1
      else rm -rf "${TARGETS[$k]}"; fi
      print -- "${C_GRN}✓${C_RST}"
      ;;
    uv)
      uv cache prune --force >/dev/null 2>&1 || uv cache prune >/dev/null 2>&1
      print -- "${C_GRN}✓${C_RST}"
      ;;
    pnpm)
      pnpm store prune >/dev/null 2>&1 && print -- "${C_GRN}✓${C_RST}" || print -- "${C_YEL}skipped${C_RST}"
      ;;
    brew)
      brew cleanup -s >/dev/null 2>&1
      rm -rf "${TARGETS[$k]}" 2>/dev/null
      print -- "${C_GRN}✓${C_RST}"
      ;;
    *)  # path type
      ps=("${(@f)TARGETS[$k]}")
      for p in $ps; do
        [[ -z "$p" || "$p" == "/" || "$p" == "$HOME" ]] && continue   # safety guard
        rm -rf "$p" 2>/dev/null
      done
      print -- "${C_GRN}✓${C_RST}"
      ;;
  esac
}

print -- ""
print -- "${C_B}== Cleanup ==${C_RST}"
free_before=$(disk_free_kb)
for k in $approved; do
  print -n -- "→ ${LABEL[$k]} ... "
  clean_one "$k"
done

# ----------------------------------------------------------------- SUMMARY ----
free_after=$(disk_free_kb)
freed=$(( free_after - free_before ))
(( freed < 0 )) && freed=0

print -- ""
print -- "${C_B}${C_GRN}== Done ==${C_RST}"
printf "Approved categories : %d\n" "${#approved}"
printf "Free space (before) : %s\n" "$(human $free_before)"
printf "Free space (after)  : %s\n" "$(human $free_after)"
printf "${C_B}Reclaimed           : ~%s${C_RST}\n" "$(human $freed)"

report_dir="${0:A:h}/reports"
mkdir -p "$report_dir" 2>/dev/null
ts=$(date +%Y%m%d-%H%M%S)
{
  print -- "clean.sh report — $ts"
  print -- "Approved: ${(j:, :)approved}"
  print -- "Reclaimed: ~$(human $freed)"
} >> "$report_dir/clean-$ts.log" 2>/dev/null
print -- "${C_DIM}Report: $report_dir/clean-$ts.log${C_RST}"
