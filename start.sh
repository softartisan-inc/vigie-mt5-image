#!/bin/bash
# Vigie — démarrage du terminal MT5 (remplace /Metatrader/start.sh de gmag11/metatrader5_vnc).
#
# Lancé par l'autostart d'openbox (KasmVNC), en tant qu'utilisateur abc. Étapes, toutes journalisées
# dans /config/vigie-mt5.log (lisible depuis le terminal Coolify du conteneur mt5) :
#   1. Wine : version et résultat de la mise à niveau faite à la construction de l'image.
#   2. Préfixe Wine (/config/.wine) : créé ou mis à jour (`wineboot -u`), jamais supprimé.
#   3. MetaTrader 5 : installé s'il est absent. L'installeur (mt5setup.exe /auto) ne rend parfois jamais
#      la main sous Wine 11 : on attend l'apparition de terminal64.exe puis on l'arrête, sans blocage.
#   4. Terminal lancé s'il ne tourne pas.
#   5. Pont RPyC (port 8001) : Python Windows préinstallé dans l'image (/opt/winpython), lancé et
#      relancé automatiquement s'il s'arrête. Vigie connecte le compte (MT5_LOGIN…) par ce pont.
# Variables : MT5_SETUP_URL (installeur du courtier, défaut : terminal générique MetaQuotes),
# MT5_WINE_WINDOWS_VERSION (win10 par défaut à la création du préfixe), MT5_CMD_OPTIONS
# (options de terminal64.exe), MT5_BRIDGE_PORT (8001).

export WINEPREFIX="${WINEPREFIX:-/config/.wine}"
export WINEDEBUG="${WINEDEBUG:--all}"
LOG=/config/vigie-mt5.log
PORT="${MT5_BRIDGE_PORT:-8001}"
MT5_DIR="$WINEPREFIX/drive_c/Program Files/MetaTrader 5"
MT5_EXE="$MT5_DIR/terminal64.exe"
WINPY=/opt/winpython

# Journal : fichier (gardé à 2 000 lignes) + sortie standard.
[ -f "$LOG" ] && tail -n 2000 "$LOG" > "$LOG.tmp" 2>/dev/null && mv "$LOG.tmp" "$LOG"
exec > >(tee -a "$LOG") 2>&1
log() { echo "$(date -u '+%Y-%m-%d %H:%M:%S') [vigie-mt5] $*"; }

log "===== Démarrage du conteneur mt5 ====="
log "1. Wine : $(wine --version 2>/dev/null || echo 'introuvable')"
if [ -f /Metatrader/wine-upgrade.log ]; then
    status="$(grep -m1 '^STATUS=' /Metatrader/wine-upgrade.log | cut -d= -f2)"
    if [ "$status" = "ok" ]; then
        log "   mise à niveau de Wine à la construction : réussie"
    else
        log "   ATTENTION : mise à niveau de Wine en échec à la construction : $(grep -m1 '^RAISON=' /Metatrader/wine-upgrade.log | cut -d= -f2-)"
    fi
fi

# 2. Préfixe Wine.
new_prefix=0
[ -f "$WINEPREFIX/system.reg" ] || new_prefix=1
log "2. Préfixe Wine $WINEPREFIX : $([ "$new_prefix" = 1 ] && echo 'création' || echo 'mise à jour')…"
if WINEDLLOVERRIDES="mscoree=d;mshtml=d" timeout 600 wine wineboot -u; then
    log "   préfixe prêt"
else
    log "   ATTENTION : wineboot a échoué (code $?), poursuite"
fi
wineserver -w 2>/dev/null || true
winver="${MT5_WINE_WINDOWS_VERSION:-}"
[ -z "$winver" ] && [ "$new_prefix" = 1 ] && winver=win10
if [ -n "$winver" ]; then
    wine reg add 'HKEY_CURRENT_USER\Software\Wine' /v Version /t REG_SZ /d "$winver" /f >/dev/null 2>&1 \
        && log "   version Windows du préfixe : $winver" || log "   impossible de régler la version Windows ($winver)"
fi

# 3. MetaTrader 5. MT5_SETUP_URL : installeur du courtier (ex. HFM), dont le terminal connaît déjà les
#    serveurs du courtier ; le terminal générique de MetaQuotes ne les trouve pas toujours sous Wine.
#    Le terminal installé par l'URL en vigueur est mémorisé ($WINEPREFIX/.vigie-mt5-dir) : changer
#    d'URL installe le nouveau terminal (dans son propre dossier) au démarrage suivant.
DEFAULT_SETUP_URL=https://download.mql5.com/cdn/web/metaquotes.software.corp/mt5/mt5setup.exe
SETUP_URL="${MT5_SETUP_URL:-$DEFAULT_SETUP_URL}"
STAMP_URL="$WINEPREFIX/.vigie-mt5-setup-url"
STAMP_DIR="$WINEPREFIX/.vigie-mt5-dir"
PF="$WINEPREFIX/drive_c/Program Files"
list_terminals() { find "$PF" -maxdepth 2 -name terminal64.exe 2>/dev/null | sort; }

if [ ! -f "$STAMP_URL" ] && [ "$SETUP_URL" = "$DEFAULT_SETUP_URL" ] && [ -f "$MT5_EXE" ]; then
    echo "$SETUP_URL" > "$STAMP_URL"; echo "$MT5_DIR" > "$STAMP_DIR"     # installation générique existante
fi
if [ -f "$STAMP_URL" ] && [ "$(cat "$STAMP_URL")" = "$SETUP_URL" ] && [ -f "$(cat "$STAMP_DIR" 2>/dev/null)/terminal64.exe" ]; then
    MT5_DIR="$(cat "$STAMP_DIR")"
    log "3. MetaTrader 5 déjà installé ($MT5_DIR)"
else
    log "3. Installation de MetaTrader 5 depuis $SETUP_URL (5 à 15 min)…"
    before="$(list_terminals)"
    setup="$WINEPREFIX/drive_c/vigie-mt5setup.exe"
    if curl -fsSL --retry 3 -o "$setup" "$SETUP_URL"; then
        wine "$setup" /auto &
        setup_pid=$!
        new_exe=""
        for _ in $(seq 1 180); do              # jusqu'à 30 min
            new_exe="$(comm -13 <(echo "$before") <(list_terminals) | head -n 1)"
            [ -n "$new_exe" ] && break
            # réinstallation dans un dossier déjà présent : on se contente de la fin de l'installeur
            if ! kill -0 "$setup_pid" 2>/dev/null; then break; fi
            sleep 10
        done
        [ -z "$new_exe" ] && new_exe="$(list_terminals | tail -n 1)"
        if [ -n "$new_exe" ]; then
            log "   terminal installé : $new_exe ; arrêt de l'installeur dans 60 s (il ne rend pas toujours la main)"
            sleep 60
            MT5_DIR="$(dirname "$new_exe")"
            echo "$SETUP_URL" > "$STAMP_URL"; echo "$MT5_DIR" > "$STAMP_DIR"
        else
            log "   ATTENTION : aucun terminal64.exe trouvé après l'installation"
        fi
        pkill -f vigie-mt5setup.exe 2>/dev/null; pkill -f mt5setup.exe 2>/dev/null; kill "$setup_pid" 2>/dev/null
        rm -f "$setup"
    else
        log "   ATTENTION : téléchargement impossible ($SETUP_URL)"
    fi
fi
MT5_EXE="$MT5_DIR/terminal64.exe"

# 4. Terminal : seul le terminal retenu tourne (un autre terminal ferait répondre la mauvaise
#    installation au module Python MetaTrader5).
mt5_name="$(basename "$MT5_DIR")"
mt5_pat="\\${mt5_name}\\terminal64"          # ex. \HFM MetaTrader 5\terminal64 (ligne de commande Wine)
others="$(pgrep -af terminal64.exe | grep -F ':\' | grep -vF "$mt5_pat" | awk '{print $1}')"
if [ -n "$others" ]; then
    log "   arrêt d'un autre terminal en cours ($(echo $others))"
    kill $others 2>/dev/null; sleep 5
fi
if pgrep -af terminal64.exe | grep -qF "$mt5_pat"; then
    log "4. Terminal déjà lancé ($mt5_name)"
elif [ -f "$MT5_EXE" ]; then
    log "4. Lancement du terminal ($MT5_EXE)"
    # shellcheck disable=SC2086
    wine "$MT5_EXE" ${MT5_CMD_OPTIONS:-} >/dev/null 2>&1 &
    sleep 20
else
    log "4. ATTENTION : terminal absent, pont lancé quand même (Vigie signalera « initialize a échoué »)"
fi

# 5. Pont RPyC, surveillé.
log "5. Pont RPyC sur le port $PORT (Python Windows préinstallé : $(cat /Metatrader/winpython-packages.txt 2>/dev/null | tr '\n' ' '))"
(
    cd "$WINPY" || exit 1
    n=0
    while true; do
        n=$((n + 1))
        log "   lancement du pont (essai $n)"
        wine python.exe vigie_bridge.py "$PORT"
        log "   ATTENTION : le pont s'est arrêté (code $?) ; relance dans 15 s"
        sleep 15
    done
) &

# Contrôle d'écoute (informatif).
for _ in $(seq 1 24); do
    if ss -ltn 2>/dev/null | grep -q ":$PORT "; then
        log "   pont à l'écoute sur :$PORT — Vigie peut se connecter (vigie check dans le conteneur engine)"
        break
    fi
    sleep 5
done
ss -ltn 2>/dev/null | grep -q ":$PORT " || log "   ATTENTION : rien n'écoute encore sur :$PORT après 2 min (voir les lignes [vigie-bridge] ci-dessus)"
log "===== Démarrage terminé (le pont reste surveillé) ====="
wait
