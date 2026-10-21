#!/bin/bash
# Vigie — mise à niveau de Wine dans l'image MT5 (appelé par docker/mt5/Dockerfile).
#
# Remplace Wine stable (10.0) de gmag11/metatrader5_vnc par WineHQ devel >= 11.6, requis par la build
# actuelle de terminal64.exe (« A debugger has been found running in your system »).
#
# NE FAIT JAMAIS ÉCHOUER LA CONSTRUCTION : en cas de problème, Wine d'origine est conservé et la
# raison est écrite dans /Metatrader/wine-upgrade.log. Ce journal apparaît dans les logs de
# construction (« Show debug logs » sur Coolify) et, au démarrage du conteneur, dans les logs du
# service mt5 (docker/mt5/start.sh). Ainsi un dépôt WineHQ indisponible ne bloque pas le déploiement
# des autres services de Vigie.
#
# Usage : upgrade-wine.sh <version> <suite debian> <révision> <empreinte de la clé WineHQ>
set -u -o pipefail

WINE_VERSION="${1:?version}"
SUITE="${2:?suite}"
REVISION="${3:?révision}"
FINGERPRINT="${4:?empreinte}"
LOG=/Metatrader/wine-upgrade.log
MIN=11.6

mkdir -p /Metatrader
: > "$LOG"
exec > >(tee -a "$LOG") 2>&1

step() { echo "== [vigie-mt5] $*"; }
finish() {
    echo "== [vigie-mt5] Wine présent : $(wine --version 2>/dev/null || echo 'introuvable')"
    echo "STATUS=$1"
    [ -n "${2:-}" ] && echo "RAISON=$2"
    exit 0
}

pkg="${WINE_VERSION}~${SUITE}-${REVISION}"
step "Système : $(. /etc/os-release && echo "$PRETTY_NAME") · Wine d'origine : $(wine --version 2>/dev/null || echo '?')"
step "Sources apt : $(ls /etc/apt/sources.list.d/ 2>/dev/null | tr '\n' ' ')"

# 1. La source WineHQ de l'image d'origine n'a plus de clé : on la retire avant tout apt-get update.
rm -f /etc/apt/sources.list.d/winehq* /etc/apt/keyrings/winehq* /usr/share/keyrings/winehq*
sed -i '/dl\.winehq\.org/d' /etc/apt/sources.list 2>/dev/null || true
mkdir -pm755 /etc/apt/keyrings

step "apt-get update (sources de base)"
apt-get -o Acquire::Retries=3 update || step "AVERTISSEMENT : apt-get update en erreur (code $?), on continue"

# 2. Outils nécessaires (souvent déjà présents).
missing=""
for t in curl gpg; do command -v "$t" >/dev/null 2>&1 || missing="$missing $t"; done
if [ -n "$missing" ]; then
    step "Installation des outils :$missing"
    apt-get install -y --no-install-recommends curl gnupg ca-certificates || finish failed "outils curl/gnupg impossibles à installer"
fi

# 3. Clé WineHQ, vérifiée par son empreinte.
step "Clé WineHQ"
curl -fsSL --retry 3 https://dl.winehq.org/wine-builds/winehq.key -o /etc/apt/keyrings/winehq-archive.key \
    || finish failed "téléchargement de la clé WineHQ impossible (dl.winehq.org injoignable ?)"
fpr="$(gpg --show-keys --with-colons /etc/apt/keyrings/winehq-archive.key 2>/dev/null | awk -F: '$1=="fpr"{print $10; exit}')"
[ "$fpr" = "$FINGERPRINT" ] || finish failed "empreinte de la clé WineHQ inattendue : ${fpr:-vide}"

printf 'Types: deb\nURIs: https://dl.winehq.org/wine-builds/debian\nSuites: %s\nComponents: main\nArchitectures: amd64 i386\nSigned-By: /etc/apt/keyrings/winehq-archive.key\n' \
    "$SUITE" > "/etc/apt/sources.list.d/winehq-${SUITE}.sources"
dpkg --add-architecture i386

step "apt-get update (avec WineHQ)"
apt-get -o Acquire::Retries=3 update || step "AVERTISSEMENT : apt-get update en erreur (code $?), on continue"

# 4. Version : la version épinglée si les QUATRE paquets existent à cette version (WineHQ publie
#    parfois amd64 avant i386 : 11.11 sans wine-devel-i386 le 21/10/2026), sinon la plus récente
#    version publiée pour les quatre, toujours >= 11.6.
step "Versions winehq-devel disponibles pour $SUITE :"
apt-cache madison winehq-devel | head -n 10
versions() { apt-cache madison "$1" 2>/dev/null | awk -F'|' '{gsub(/ /,"",$2); print $2}'; }
complete_versions() {
    versions winehq-devel | while read -r cand; do
        [ -n "$cand" ] || continue
        ok=1
        for p in wine-devel wine-devel-amd64 wine-devel-i386:i386; do
            versions "$p" | grep -xF "$cand" >/dev/null || { ok=0; break; }   # pas de -q : avec pipefail, une sortie anticipée de grep ferait échouer le tube
        done
        [ "$ok" = 1 ] && echo "$cand"
    done
}
avail="$(complete_versions)"
step "Versions complètes (amd64 + i386) : $(echo "$avail" | head -n 5 | tr '\n' ' ')"
if ! echo "$avail" | grep -qxF "$pkg"; then
    pkg="$(echo "$avail" | sort -V -r | head -n 1)"
    [ -n "$pkg" ] || finish failed "aucune version winehq-devel complète (amd64 + i386) publiée pour $SUITE"
    step "Version épinglée ${WINE_VERSION} absente ou incomplète : repli sur $pkg"
fi
dpkg --compare-versions "${pkg%%~*}" ge "$MIN" || finish failed "winehq-devel $pkg < $MIN"

# 5. Installation (apt retire winehq-stable, en conflit). En cas d'échec, rien n'est changé.
step "Installation de winehq-devel $pkg"
if ! apt-get install -y --install-recommends \
        "winehq-devel=${pkg}" "wine-devel=${pkg}" "wine-devel-amd64=${pkg}" "wine-devel-i386:i386=${pkg}"; then
    step "Diagnostic des dépendances :"
    apt-get install -s "winehq-devel=${pkg}" 2>&1 | tail -n 25
    finish failed "installation de winehq-devel $pkg impossible (voir ci-dessus)"
fi
apt-mark hold winehq-devel wine-devel wine-devel-amd64 wine-devel-i386:i386 || true

v="$(wine --version 2>/dev/null | sed -e 's/^wine-//' -e 's/[ (].*//')"
dpkg --compare-versions "${v:-0}" ge "$MIN" || finish failed "Wine installé ${v:-?} < $MIN"
apt-get clean
rm -rf /var/lib/apt/lists/*
finish ok
