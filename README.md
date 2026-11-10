# vps-health

Supervision légère d'un VPS Linux avec alerte WhatsApp via [WAHA](https://waha.devlike.pro/).
Un timer systemd lance `check.sh` toutes les 15 minutes ; un message est envoyé à l'entrée
en alerte et un autre au retour à la normale, jamais entre les deux.

Contrôles :

- disque (`/` par défaut) au-dessus d'un seuil en pourcentage ;
- swap utilisée au-dessus d'un seuil en Mo ;
- conteneurs Docker à politique `unless-stopped`/`always` arrêtés ou `unhealthy`.

## Installation

```bash
git clone https://github.com/EagleFox31/vps-health.git /tmp/vps-health
cd /tmp/vps-health
sudo VPS_HEALTH_RECIPIENT=2376XXXXXXXX WAHA_ENV=/chemin/vers/waha/.env ./install.sh
```

`install.sh` est idempotent : il copie les fichiers dans `/opt/vps-health`, pose les unités
systemd, crée `/etc/vps-health.env` (root, 0600) uniquement s'il n'existe pas, puis active le
timer. Une relance sans changement n'écrit rien (`aucun changement (convergé)`).

La clé d'API WAHA est lue dans le fichier `.env` de WAHA (`WAHA_API_KEY=`) et recopiée dans
`/etc/vps-health.env`. Elle n'apparaît jamais sur la ligne de commande ni dans les journaux.

## Configuration (`/etc/vps-health.env`)

| Clé | Défaut | Rôle |
|---|---|---|
| `WAHA_URL` | `http://127.0.0.1:3000` | URL de l'API WAHA |
| `WAHA_SESSION` | `default` | Session WAHA utilisée pour l'envoi |
| `WAHA_API_KEY` | — | Clé d'API (requise) |
| `RECIPIENT` | — | Numéro destinataire, chiffres seulement (requis) |
| `DISK_PCT_MAX` | `85` | Seuil disque en % |
| `SWAP_MB_MAX` | `1536` | Seuil swap en Mo |
| `DISK_PATH` | `/` | Point de montage surveillé |
| `HOST_LABEL` | `hostname` | Libellé dans les messages |
| `STATE_FILE` | `/var/lib/vps-health/state` | État des alertes actives |

## Tests

```bash
sudo /opt/vps-health/check.sh --test                       # message de test réel
sudo /opt/vps-health/check.sh --dry-run                    # mesure sans envoi
sudo /opt/vps-health/check.sh --simulate disk=90,swap=2000 # alerte simulée (état séparé)
sudo /opt/vps-health/check.sh --simulate none              # retour à la normale simulé
```

## Exploitation

```bash
systemctl list-timers vps-health.timer
journalctl -u vps-health.service -n 20
sudo /opt/vps-health/install.sh --uninstall   # retire les unités, garde /opt, config et état
```

Le service tourne avec `MemoryMax=64M`, `CPUQuota=20%`, `ProtectSystem=strict` et
`ProtectHome=yes`.

## Licence

MIT.
