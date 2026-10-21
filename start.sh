#!/bin/bash
# Vigie — démarrage du terminal MT5 (remplace /Metatrader/start.sh de gmag11/metatrader5_vnc).
#
# Lancé par l'autostart d'openbox (KasmVNC), comme le script d'origine. Il prépare le préfixe Wine,
# puis passe la main au script d'origine (/Metatrader/start-upstream.sh), qui installe Mono,
# MetaTrader 5, le Python Windows et démarre le pont mt5linux/RPyC sur le port 8001.
#
# 1. Préfixe existant (par exemple créé par Wine 10 dans le volume mt5-config) : mis à jour par
#    `wineboot -u` pour la version de Wine de l'image. Rien n'est supprimé.
# 2. Préfixe absent : créé par `wineboot -u`.
#    Dans les deux cas, Mono et Gecko sont désactivés pendant wineboot pour qu'aucune fenêtre
#    d'installation ne bloque le démarrage (Mono est installé ensuite par le script d'origine).
# 3. MT5_WINE_WINDOWS_VERSION (win10, win11…) : appliquée au préfixe à chaque démarrage si définie.

export WINEPREFIX="${WINEPREFIX:-/config/.wine}"
export WINEDEBUG="${WINEDEBUG:--all}"

log() { echo "[vigie-mt5] $*"; }

log "Version de Wine : $(wine --version 2>/dev/null || echo 'introuvable')"
if [ -f /Metatrader/wine-upgrade.log ]; then
    status="$(grep -m1 '^STATUS=' /Metatrader/wine-upgrade.log | cut -d= -f2)"
    if [ "$status" = "ok" ]; then
        log "Mise à niveau de Wine à la construction : réussie."
    else
        log "ATTENTION : la mise à niveau de Wine a échoué à la construction ; Wine d'origine conservé."
        log "Raison : $(grep -m1 '^RAISON=' /Metatrader/wine-upgrade.log | cut -d= -f2-)"
        log "Journal complet de la construction (fin) :"
        tail -n 40 /Metatrader/wine-upgrade.log | sed 's/^/[vigie-mt5]   /'
    fi
fi
if [ -f "$WINEPREFIX/system.reg" ]; then
    log "Préfixe Wine existant ($WINEPREFIX) : mise à jour (plusieurs minutes après un changement de version de Wine)…"
else
    log "Aucun préfixe Wine dans $WINEPREFIX : création…"
fi

if WINEDLLOVERRIDES="mscoree=d;mshtml=d" wine wineboot -u; then
    log "Préfixe Wine prêt."
else
    log "wineboot a échoué (code $?) : poursuite du démarrage. Si le terminal ne démarre pas, voir docs/deploiement-coolify.md."
fi
if command -v wineserver >/dev/null 2>&1; then
    wineserver -w || true
fi

if [ -n "${MT5_WINE_WINDOWS_VERSION:-}" ]; then
    if wine reg add 'HKEY_CURRENT_USER\Software\Wine' /v Version /t REG_SZ /d "$MT5_WINE_WINDOWS_VERSION" /f >/dev/null 2>&1; then
        log "Version Windows du préfixe : $MT5_WINE_WINDOWS_VERSION"
    else
        log "Impossible de régler la version Windows du préfixe sur $MT5_WINE_WINDOWS_VERSION"
    fi
fi

exec /Metatrader/start-upstream.sh "$@"
