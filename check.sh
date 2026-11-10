#!/usr/bin/env bash
# vps-health : contrôle léger disque / swap / conteneurs, alerte WhatsApp via WAHA.
# Un message à l'entrée en alerte, un au retour à la normale ; relance sans changement = aucun envoi.
# Usage : check.sh [--test] [--dry-run] [--simulate disk=90,swap=2000,container=nom | --simulate none]
set -euo pipefail
CONFIG="${VPS_HEALTH_CONFIG:-/etc/vps-health.env}"
MODE=run; DRY=0; SIM=""
while [ $# -gt 0 ]; do
  case "$1" in
    --test) MODE=test ;;
    --dry-run) DRY=1 ;;
    --simulate) SIM="${2:-none}"; shift ;;
    *) echo "argument inconnu : $1" >&2; exit 2 ;;
  esac; shift
done
[ -r "$CONFIG" ] || { echo "config absente ou illisible : $CONFIG" >&2; exit 2; }
# shellcheck disable=SC1090
set -a; . "$CONFIG"; set +a
: "${WAHA_URL:=http://127.0.0.1:3000}" "${WAHA_SESSION:=default}" "${DISK_PCT_MAX:=85}" "${SWAP_MB_MAX:=1536}"
: "${STATE_FILE:=/var/lib/vps-health/state}" "${HOST_LABEL:=$(hostname)}" "${DISK_PATH:=/}"
: "${WAHA_API_KEY:?WAHA_API_KEY manquant dans $CONFIG}" "${RECIPIENT:?RECIPIENT manquant dans $CONFIG}"
[ -n "$SIM" ] && STATE_FILE="${STATE_FILE}.simulate"
mkdir -p "$(dirname "$STATE_FILE")"
exec 9>"${STATE_FILE}.lock"; flock -w 30 9 || { echo "verrou occupé" >&2; exit 1; }

send() { # $1 = texte ; la clé ne passe jamais par la ligne de commande (curl -K sur stdin)
  if [ "$DRY" = 1 ]; then printf '[dry-run] %s\n' "$1"; return 0; fi
  local body code
  body=$(jq -cn --arg s "$WAHA_SESSION" --arg c "${RECIPIENT}@c.us" --arg t "$1" '{session:$s,chatId:$c,text:$t}')
  code=$(curl -sS -o /dev/null -w '%{http_code}' -m 15 -K - <<CFG
url = "${WAHA_URL}/api/sendText"
header = "X-Api-Key: ${WAHA_API_KEY}"
header = "Content-Type: application/json"
data = $(jq -cn --arg b "$body" '$b')
CFG
  ) || { echo "envoi WAHA impossible (réseau)" >&2; return 1; }
  case "$code" in 2*) return 0 ;; *) echo "envoi WAHA refusé : HTTP $code" >&2; return 1 ;; esac
}

now=$(date '+%d/%m/%Y %H:%M %Z')
icon() { case "$1" in disk) printf '💾' ;; swap) printf '🧠' ;; container:*) printf '🐳' ;; *) printf '•' ;; esac; }
label() { case "$1" in disk) printf 'Disque %s' "$DISK_PATH" ;; swap) printf 'Swap' ;; container:*) printf 'Conteneur %s' "${1#container:}" ;; *) printf '%s' "$1" ;; esac; }
if [ "$MODE" = test ]; then
  send "🩺 *vps-health* · ${HOST_LABEL}
✅ Message de test
🕒 ${now}

Seuils surveillés :
💾 Disque ≥ ${DISK_PCT_MAX} %
🧠 Swap ≥ ${SWAP_MB_MAX} Mo
🐳 Conteneurs arrêtés ou unhealthy"
  echo "message de test envoyé"; exit 0
fi

# --- mesures (lecture seule) ---
disk_pct=$(df --output=pcent "$DISK_PATH" | tail -1 | tr -dc '0-9')
disk_free=$(df -h --output=avail "$DISK_PATH" | tail -1 | tr -d ' ')
swap_mb=$(awk '/SwapTotal/{t=$2}/SwapFree/{f=$2}END{print int((t-f)/1024)}' /proc/meminfo)
declare -A bad_containers=()
while IFS='|' read -r name policy status health; do
  name=${name#/}
  [ -n "$name" ] || continue
  [ "$policy" = unless-stopped ] || [ "$policy" = always ] || continue
  if [ "$status" != running ]; then bad_containers["$name"]="$status"
  elif [ "$health" = unhealthy ]; then bad_containers["$name"]="unhealthy"; fi
done < <(docker ps -aq | xargs -r docker inspect --format '{{.Name}}|{{.HostConfig.RestartPolicy.Name}}|{{.State.Status}}|{{if .State.Health}}{{.State.Health.Status}}{{end}}' 2>/dev/null || true)

if [ -n "$SIM" ]; then
  IFS=',' read -ra kv <<<"$SIM"
  for pair in "${kv[@]}"; do
    case "$pair" in
      disk=*) disk_pct=${pair#disk=} ;;
      swap=*) swap_mb=${pair#swap=} ;;
      container=*) bad_containers["${pair#container=}"]="simulé" ;;
      none) disk_pct=0; swap_mb=0; bad_containers=() ;;
    esac
  done
fi

# --- état courant : une clé par incident (sans la valeur, pour ne pas renvoyer à chaque variation) ---
declare -A detail=()
[ "$disk_pct" -ge "$DISK_PCT_MAX" ] && detail[disk]="${disk_pct} % utilisés (${disk_free} libres, seuil ${DISK_PCT_MAX} %)"
[ "$swap_mb" -ge "$SWAP_MB_MAX" ] && detail[swap]="${swap_mb} Mo utilisés (seuil ${SWAP_MB_MAX} Mo)"
for c in "${!bad_containers[@]}"; do detail["container:$c"]="${bad_containers[$c]}"; done
current=""; [ "${#detail[@]}" -gt 0 ] && current=$(printf '%s\n' "${!detail[@]}" | sort)
previous=""; [ -f "$STATE_FILE" ] && previous=$(sort "$STATE_FILE")
new=$(comm -13 <(printf '%s\n' "$previous") <(printf '%s\n' "$current") | sed '/^$/d')
resolved=$(comm -23 <(printf '%s\n' "$previous") <(printf '%s\n' "$current") | sed '/^$/d')

if [ -z "$new" ] && [ -z "$resolved" ]; then echo "aucun changement (alertes actives : $(printf '%s' "${current:-aucune}" | tr '
' ' ')"; exit 0; fi
if [ -n "$new" ]; then msg="🚨 *ALERTE* · ${HOST_LABEL}"; else msg="✅ *Retour à la normale* · ${HOST_LABEL}"; fi
msg+=$'\n'"🕒 ${now}"
if [ -n "$new" ]; then
  msg+=$'\n\n'"Nouveau :"
  while read -r k; do [ -n "$k" ] && msg+=$'\n'"$(icon "$k") $(label "$k") : ${detail[$k]}"; done <<<"$new"
fi
if [ -n "$resolved" ]; then
  msg+=$'\n\n'"Résolu :"
  while read -r k; do [ -n "$k" ] && msg+=$'\n'"$(icon "$k") $(label "$k") ✔"; done <<<"$resolved"
fi
still=$(comm -12 <(printf '%s\n' "$previous") <(printf '%s\n' "$current") | sed '/^$/d')
if [ -n "$still" ]; then
  msg+=$'\n\n'"Toujours en cours :"
  while read -r k; do [ -n "$k" ] && msg+=$'\n'"$(icon "$k") $(label "$k") : ${detail[$k]}"; done <<<"$still"
fi
[ -n "$SIM" ] && msg+=$'\n\n'"_(simulation, pas une mesure réelle)_"
send "$msg"
tmp=$(mktemp "${STATE_FILE}.XXXXXX"); printf '%s\n' "$current" | sed '/^$/d' >"$tmp"; mv -f "$tmp" "$STATE_FILE"
echo "notification envoyée ; nouvelles : $(printf '%s' "$new" | tr '\n' ' ') ; résolues : $(printf '%s' "$resolved" | tr '\n' ' ')"
