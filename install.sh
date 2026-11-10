#!/usr/bin/env bash
# Installation idempotente de vps-health. Relancer sans changement = aucune écriture.
# Env : VPS_HEALTH_RECIPIENT (chiffres, requis seulement à la création de la config),
#       WAHA_ENV (chemin du .env de WAHA, source de la clé d'API, jamais affichée)
# Usage : sudo -E ./install.sh [--uninstall]
set -euo pipefail
SRC=$(cd "$(dirname "$0")" && pwd); DEST=/opt/vps-health; CONF=/etc/vps-health.env; STATE=/var/lib/vps-health
[ "$(id -u)" = 0 ] || { echo "lancer avec sudo" >&2; exit 2; }
if [ "${1:-}" = --uninstall ]; then
  systemctl disable --now vps-health.timer 2>/dev/null || true
  rm -f /etc/systemd/system/vps-health.service /etc/systemd/system/vps-health.timer; systemctl daemon-reload
  echo "unités retirées ; conservés : $DEST $CONF $STATE (à supprimer à la main si voulu)"; exit 0
fi
changed=0
put() { # src dest mode
  if [ ! -f "$2" ] || ! cmp -s "$1" "$2"; then install -m "$3" -o root -g root "$1" "$2"; echo "écrit : $2"; changed=1
  elif [ "$(stat -c %a "$2")" != "$3" ]; then chmod "$3" "$2"; echo "droits : $2"; changed=1; fi
}
install -d -m 755 "$DEST"; install -d -m 750 "$STATE"
put "$SRC/check.sh" "$DEST/check.sh" 755
put "$SRC/install.sh" "$DEST/install.sh" 755
put "$SRC/vps-health.service" "$DEST/vps-health.service" 644
put "$SRC/vps-health.timer" "$DEST/vps-health.timer" 644
put "$SRC/vps-health.service" /etc/systemd/system/vps-health.service 644
put "$SRC/vps-health.timer" /etc/systemd/system/vps-health.timer 644
if [ ! -f "$CONF" ]; then
  : "${VPS_HEALTH_RECIPIENT:?VPS_HEALTH_RECIPIENT requis pour créer $CONF}"
  WAHA_ENV="${WAHA_ENV:?WAHA_ENV requis : chemin du .env de WAHA}"
  key=$(grep -E '^WAHA_API_KEY=' "$WAHA_ENV" | head -1 | cut -d= -f2- | tr -d "\"' ")
  [ -n "$key" ] || { echo "WAHA_API_KEY introuvable dans $WAHA_ENV" >&2; exit 2; }
  umask 077
  cat >"$CONF" <<CFG
# vps-health : fichier privé (root:root 0600), jamais versionné
WAHA_URL=http://127.0.0.1:3000
WAHA_SESSION=${WAHA_SESSION:-default}
WAHA_API_KEY=${key}
RECIPIENT=${VPS_HEALTH_RECIPIENT}
DISK_PCT_MAX=85
SWAP_MB_MAX=1536
HOST_LABEL=$(hostname)
CFG
  chmod 600 "$CONF"; echo "écrit : $CONF (0600)"; changed=1
fi
[ "$changed" = 1 ] && systemctl daemon-reload
if ! systemctl is-enabled -q vps-health.timer 2>/dev/null || ! systemctl is-active -q vps-health.timer; then
  systemctl enable --now vps-health.timer; echo "timer activé"; changed=1
fi
if [ "$changed" = 1 ]; then echo "install.sh : modifications appliquées"; else echo "install.sh : aucun changement (convergé)"; fi
