#!/usr/bin/env zsh
#
# clean.sh — güvenli geliştirici cache temizleyici (macOS)
#
# Akış: analiz et -> raporla -> kategori bazında onay iste -> sadece onaylananı sil.
# Native temizlik komutu varsa onu kullanır (docker/go/npm/uv/pnpm/brew),
# yoksa rm -rf ile sadece bilinen cache yollarını siler.
#
# Sadece YENIDEN ÜRETILEBILIR cache verisi hedeflenir. iCloud, proje kodu,
# tarayıcı profili gibi gerçek veriye ASLA dokunulmaz.
#
# Kullanım:
#   ./clean.sh                 interaktif (analiz + rapor + onay + sil)
#   ./clean.sh --dry-run       sadece analiz ve rapor; hiçbir şey silmez
#   ./clean.sh --yes           tüm uygun kategorileri onaysız sil (volume hariç)
#   ./clean.sh --only docker,npm   sadece belirtilen kategoriler
#   ./clean.sh --docker-volumes    Docker named volume'leri de buda (RISKLI)
#   ./clean.sh --help

emulate -L zsh
setopt no_unset pipe_fail

# ---------------------------------------------------------------- renkler ----
if [[ -t 1 ]]; then
  C_RST=$'\e[0m'; C_DIM=$'\e[2m'; C_B=$'\e[1m'
  C_GRN=$'\e[32m'; C_YEL=$'\e[33m'; C_RED=$'\e[31m'; C_CYN=$'\e[36m'
else
  C_RST=''; C_DIM=''; C_B=''; C_GRN=''; C_YEL=''; C_RED=''; C_CYN=''
fi

# --------------------------------------------------------------- bayraklar ----
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
    --help|-h)        sed -n '3,26p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) print -ru2 -- "${C_RED}Bilinmeyen argüman: $1${C_RST}"; exit 2 ;;
  esac
  shift
done

# --------------------------------------------------------------- yardımcı ----
have() { command -v "$1" >/dev/null 2>&1; }

# kilobayt -> insan okunur
human() {
  local kb=$1
  if   (( kb >= 1048576 )); then printf '%.1fG' "$(( kb / 1048576.0 ))"
  elif (( kb >= 1024 ));    then printf '%.0fM' "$(( kb / 1024.0 ))"
  else printf '%dK' "$kb"
  fi
}

# bir veya birden çok yolun toplam boyutu (KB); yoksa 0
path_kb() {
  local total=0 p="" sz=""
  for p in "$@"; do
    [[ -e "$p" ]] || continue
    sz=$(/usr/bin/du -sk "$p" 2>/dev/null | awk '{print $1}')
    [[ -n "$sz" ]] && (( total += sz ))
  done
  print -- "$total"
}

# kök diskte boş alan (KB)
disk_free_kb() { /bin/df -k / | awk 'NR==2{print $4}'; }

# evet/hayır sor (varsayılan: hayır)
confirm() {
  local prompt="$1" reply=""
  (( ASSUME_YES )) && return 0
  read "reply?$prompt [e/H]: "
  [[ "$reply" == (e|E|y|Y|evet|yes) ]]
}

# -------------------------------------------------------------- kayıt defteri -
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

register docker     tool "Docker (imaj/container/build cache)" caution \
  "Kullanılmayan imajlar, durmuş container'lar ve build cache."
register claude_vm  path "Claude local-agent VM bundle'ları"   caution \
  "Local agent mode VM imajları. Silinirse tekrar indirilir."
TARGETS[claude_vm]="$H/Library/Application Support/Claude/vm_bundles"

register go_modcache tool "Go module cache"                    safe \
  "İndirilmiş Go modülleri. Sonraki build'de yeniden iner."
TARGETS[go_modcache]="$H/go/pkg/mod"

register npm        tool "npm cache"                           safe \
  "npm paket cache'i (_cacache). Yeniden indirilir."
TARGETS[npm]="$H/.npm/_cacache"

register uv         tool "uv cache"                            safe \
  "Python (uv) paket cache'i. Kullanılmayan girdiler budanır."
TARGETS[uv]="$H/.cache/uv"

register pnpm       tool "pnpm store"                          safe \
  "pnpm global içerik deposu. Referanssız paketler budanır."

register playwright path "Playwright tarayıcı binary'leri"     safe \
  "İndirilmiş tarayıcılar. Sonraki kullanımda tekrar iner."
TARGETS[playwright]="$H/Library/Caches/ms-playwright"

register codex      path "codex-runtimes cache"                safe \
  "Codex runtime indirme cache'i."
TARGETS[codex]="$H/.cache/codex-runtimes"

register copilot    path "github-copilot cache"                safe \
  "GitHub Copilot cache'i."
TARGETS[copilot]="$H/.cache/github-copilot"

register brew       tool "Homebrew indirme cache"              safe \
  "İndirilmiş formula/bottle arşivleri."

register pip        tool "pip cache"                           safe \
  "Python pip wheel/indirme cache'i."

register misc       path "Diğer araç cache'leri"               safe \
  "golangci-lint, outlines, node, nvim cache'leri."
TARGETS[misc]="$H/.cache/golangci-lint
$H/.cache/outlines
$H/.cache/node
$H/.cache/nvim"

# --only filtresi
if [[ -n "$ONLY" ]]; then
  local -a keep=("${(@s:,:)ONLY}") filtered=()
  for k in $ORDER; do
    [[ " ${keep[*]} " == *" $k "* ]] && filtered+=("$k")
  done
  ORDER=("${filtered[@]}")
  (( ${#ORDER} )) || { print -ru2 -- "${C_RED}--only ile eşleşen kategori yok.${C_RST}"; exit 2; }
fi

# ---------------------------------------------------------------- ANALIZ ------
# Tek kategori analizi (fonksiyon: local'lar burada güvenle çalışır)
analyze_key() {
  local k=$1 rec="" sp="" bc="" pc="" p=""
  local -a ps=()
  case "$k" in
    docker)
      if have docker && docker info >/dev/null 2>&1; then
        AVAIL[$k]=1
        SIZE_KB[$k]=$(path_kb "$H/Library/Containers/com.docker.docker/Data/vms")
        rec=$(docker system df --format '{{.Type}}: {{.Reclaimable}}' 2>/dev/null | paste -sd'; ' -)
        NOTE[$k]="geri kazanılabilir → ${rec}"
      else
        NOTE[$k]="docker daemon kapalı/erişilemez — atlanır"
      fi
      ;;
    go_modcache)
      [[ -d "${TARGETS[$k]}" ]] && { AVAIL[$k]=1; SIZE_KB[$k]=$(path_kb "${TARGETS[$k]}"); }
      have go || NOTE[$k]="(go yok; chmod+rm ile silinir)"
      ;;
    npm)
      [[ -d "${TARGETS[$k]}" ]] && { AVAIL[$k]=1; SIZE_KB[$k]=$(path_kb "${TARGETS[$k]}"); }
      ;;
    uv)
      if have uv && [[ -d "${TARGETS[$k]}" ]]; then
        AVAIL[$k]=1; SIZE_KB[$k]=$(path_kb "${TARGETS[$k]}")
        NOTE[$k]="prune sadece kullanılmayanı siler (hepsini değil)"
      fi
      ;;
    pnpm)
      if have pnpm; then
        sp=$(pnpm store path 2>/dev/null)
        if [[ -n "$sp" && -d "$sp" ]]; then
          AVAIL[$k]=1; SIZE_KB[$k]=$(path_kb "$sp"); TARGETS[$k]="$sp"
          NOTE[$k]="prune sadece referanssızı siler"
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
    *)  # path türü
      ps=("${(@f)TARGETS[$k]}")
      for p in $ps; do [[ -e "$p" ]] && AVAIL[$k]=1; done
      (( AVAIL[$k] )) && SIZE_KB[$k]=$(path_kb "${ps[@]}")
      ;;
  esac
}

print -- "${C_B}${C_CYN}== Cache analizi yapılıyor... ==${C_RST}"
for k in $ORDER; do analyze_key "$k"; done

# ---------------------------------------------------------------- RAPOR -------
render_row() {
  local idx=$1 k=$2 tag="" color=""
  if [[ "${SAFETY[$k]}" == safe ]]; then tag="güvenli"; color="$C_GRN"
  else tag="dikkat"; color="$C_YEL"; fi
  printf "%-3s %-42s %8s  ${color}%s${C_RST}\n" "$idx." "${LABEL[$k]}" "$(human ${SIZE_KB[$k]})" "$tag"
  print -- "    ${C_DIM}${DESC[$k]}${C_RST}"
  [[ -n "${NOTE[$k]}" ]] && print -- "    ${C_DIM}↳ ${NOTE[$k]}${C_RST}"
}

print -- ""
print -- "${C_B}╔══════════════════════════════════════════════════════════════╗${C_RST}"
print -- "${C_B}║  CACHE TEMIZLIK RAPORU                                        ║${C_RST}"
print -- "${C_B}╚══════════════════════════════════════════════════════════════╝${C_RST}"

# boyuta göre azalan sırala (sadece uygun olanlar)
typeset -a rows=()
total_kb=0
for k in $ORDER; do
  (( AVAIL[$k] )) || continue
  rows+=("${SIZE_KB[$k]}|$k")
  (( total_kb += SIZE_KB[$k] ))
done
typeset -a sorted=("${(@On)rows}")   # numeric, azalan

if (( ${#sorted} == 0 )); then
  print -- "${C_YEL}Temizlenecek uygun cache bulunamadı.${C_RST}"
else
  printf "${C_DIM}%-3s %-42s %8s  %s${C_RST}\n" "#" "Kategori" "Boyut" "Güvenlik"
  print -- "${C_DIM}─────────────────────────────────────────────────────────────────${C_RST}"
  i=0
  for row in $sorted; do
    i=$(( i + 1 ))
    render_row "$i" "${row#*|}"
  done
  print -- "${C_DIM}─────────────────────────────────────────────────────────────────${C_RST}"
  printf "${C_B}%-46s %8s${C_RST}\n" "TOPLAM (üst sınır)" "$(human $total_kb)"
fi

# atlananları kısaca listele
typeset -a skipped=()
for k in $ORDER; do
  (( AVAIL[$k] )) && continue
  [[ -n "${NOTE[$k]}" ]] && skipped+=("${LABEL[$k]} — ${NOTE[$k]}")
done
(( ${#skipped} )) && { print -- ""; print -- "${C_DIM}Atlanan: ${(j:; :)skipped}${C_RST}"; }

if (( DRY_RUN )); then
  print -- ""
  print -- "${C_CYN}--dry-run: hiçbir şey silinmedi.${C_RST}"
  exit 0
fi
(( ${#sorted} )) || exit 0

# --------------------------------------------------------------- ONAY ---------
print -- ""
print -- "${C_B}== Onay aşaması ==${C_RST} ${C_DIM}(varsayılan Hayır; sadece 'e' silme onayıdır)${C_RST}"

typeset -a approved=()
for row in $sorted; do
  k="${row#*|}"
  prompt="${C_B}${LABEL[$k]}${C_RST} (${C_CYN}$(human ${SIZE_KB[$k]})${C_RST}) silinsin mi?"
  [[ "${SAFETY[$k]}" == caution ]] && prompt="${C_YEL}[dikkat]${C_RST} $prompt"
  confirm "$prompt" && approved+=("$k")
done

if (( ${#approved} == 0 )); then
  print -- ""; print -- "${C_YEL}Hiçbir kategori onaylanmadı. Çıkılıyor.${C_RST}"; exit 0
fi

# --------------------------------------------------------------- TEMIZLIK -----
clean_one() {
  local k=$1 lvl=2 lr="" p=""
  local -a ps=()
  case "$k" in
    docker)
      if (( ! ASSUME_YES )); then
        print -- ""
        print -- "  Docker seviyesi seç:"
        print -- "    ${C_DIM}1) dangling (asılı imaj + durmuş container)${C_RST}"
        print -- "    ${C_DIM}2) tüm kullanılmayan imajlar (volume korunur) [önerilen]${C_RST}"
        print -- "    ${C_DIM}3) + named volume'ler (RISKLI: DB verisi gidebilir)${C_RST}"
        read "lr?  Seçim [1/2/3, varsayılan 2]: "
        case "$lr" in 1) lvl=1;; 3) lvl=3;; *) lvl=2;; esac
      else
        (( DOCKER_VOLUMES )) && lvl=3 || lvl=2
      fi
      case "$lvl" in
        1) docker system prune -f ;;
        2) docker system prune -af ;;
        3) docker system prune -af --volumes ;;
      esac
      print -- "  ${C_GRN}✓ docker prune (seviye $lvl)${C_RST}"
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
      pnpm store prune >/dev/null 2>&1 && print -- "${C_GRN}✓${C_RST}" || print -- "${C_YEL}atlandı${C_RST}"
      ;;
    brew)
      brew cleanup -s >/dev/null 2>&1
      rm -rf "${TARGETS[$k]}" 2>/dev/null
      print -- "${C_GRN}✓${C_RST}"
      ;;
    *)  # path türü
      ps=("${(@f)TARGETS[$k]}")
      for p in $ps; do
        [[ -z "$p" || "$p" == "/" || "$p" == "$HOME" ]] && continue   # güvenlik
        rm -rf "$p" 2>/dev/null
      done
      print -- "${C_GRN}✓${C_RST}"
      ;;
  esac
}

print -- ""
print -- "${C_B}== Temizlik ==${C_RST}"
free_before=$(disk_free_kb)
for k in $approved; do
  print -n -- "→ ${LABEL[$k]} ... "
  clean_one "$k"
done

# --------------------------------------------------------------- ÖZET ---------
free_after=$(disk_free_kb)
freed=$(( free_after - free_before ))
(( freed < 0 )) && freed=0

print -- ""
print -- "${C_B}${C_GRN}== Tamamlandı ==${C_RST}"
printf "Onaylanan kategori : %d\n" "${#approved}"
printf "Boş alan (önce)    : %s\n" "$(human $free_before)"
printf "Boş alan (sonra)   : %s\n" "$(human $free_after)"
printf "${C_B}Açılan alan        : ~%s${C_RST}\n" "$(human $freed)"

report_dir="${0:A:h}/reports"
mkdir -p "$report_dir" 2>/dev/null
ts=$(date +%Y%m%d-%H%M%S)
{
  print -- "clean.sh raporu — $ts"
  print -- "Onaylanan: ${(j:, :)approved}"
  print -- "Açılan alan: ~$(human $freed)"
} >> "$report_dir/clean-$ts.log" 2>/dev/null
print -- "${C_DIM}Rapor: $report_dir/clean-$ts.log${C_RST}"
