# Vigie — terminal MetaTrader 5 sous Wine (service `mt5` de docker-compose.yml).
#
# Dérivée de gmag11/metatrader5_vnc, épinglée. Seul Wine change : l'image d'origine installe
# `winehq-stable` non épinglé (Wine 10.0), avec lequel la build actuelle de terminal64.exe (6266)
# s'arrête sur « A debugger has been found running in your system ». Le DRM du terminal fait des
# appels système directs que Wine ne gère qu'à partir de 11.6 (Wine bug 58043, Syscall User
# Dispatch : noyau hôte ≥ 5.11, `prctl` autorisé par seccomp, ce qui est le cas par défaut avec Docker).
#
# Inchangé : KasmVNC sur le port 3000, /defaults/autostart → /Metatrader/start.sh, WINEPREFIX=/config/.wine,
# volume /config. Remplacés : Python Windows et pont RPyC (port 8001) préinstallés dans /opt/winpython ;
# démarrage piloté par docker/mt5/start.sh (journal /config/vigie-mt5.log).
# Voir docs/deploiement-coolify.md (« Terminal MT5 : image construite et Wine ») et docs/reference.md.

# Tag 2.3 (20/12/2025) = « latest » à la date de l'épinglage. Pour épingler aussi le digest :
#   --build-arg MT5_BASE_IMAGE=gmag11/metatrader5_vnc:2.3@sha256:<digest lu sur Docker Hub>
ARG MT5_BASE_IMAGE=gmag11/metatrader5_vnc:2.3
FROM ${MT5_BASE_IMAGE}
ARG MT5_BASE_IMAGE

# WineHQ devel, version exacte (≥ 11.6 obligatoire). 11.10 : plus récente version complète (amd64 + i386)
# publiée pour bookworm au 21/10/2026 (11.11 sans i386, 11.19 réservée à trixie). Repli automatique sinon.
# Pour mémoire, 11.19 est la version validée avec la build
# MT5 6266 par un projet similaire (swing-traders/mt5-connector, PR 23).
ARG WINE_VERSION=11.10
ARG WINE_DEBIAN_SUITE=bookworm
ARG WINE_PACKAGE_REVISION=1
# Wine Mono attendu par Wine 11.19 (MONO_VERSION de dlls/appwiz.cpl/addons.c).
ARG WINE_MONO_VERSION=11.3.0
# Empreinte de la clé de signature des paquets WineHQ.
ARG WINEHQ_REPO_FINGERPRINT=D43F640145369C51D786DDEA76F1A20FF987672F

LABEL org.opencontainers.image.title="vigie-mt5" \
      org.opencontainers.image.description="MetaTrader 5 sous WineHQ devel ${WINE_VERSION} (base ${MT5_BASE_IMAGE})"

# MT5_WINE_WINDOWS_VERSION : version Windows du préfixe (win10, win11…). Vide : inchangée
# (l'installation initiale de l'image d'origine règle win10).
ENV WINEPREFIX=/config/.wine \
    WINEDEBUG=-all \
    MT5_WINE_WINDOWS_VERSION=""

# Mise à niveau de Wine (docker/mt5/upgrade-wine.sh). Elle ne fait JAMAIS échouer la construction :
# en cas de problème (dépôt WineHQ injoignable, version absente, conflit de dépendances), Wine d'origine
# est conservé et la raison est écrite dans /Metatrader/wine-upgrade.log, affiché au démarrage du
# conteneur (logs du service mt5) et dans les logs de construction. Les versions acceptées : la version
# épinglée ci-dessus, sinon la plus récente winehq-devel publiée, et toujours >= 11.6.
# Paquets installés : "winehq-devel=${pkg}" "wine-devel=${pkg}" "wine-devel-amd64=${pkg}" "wine-devel-i386:i386=${pkg}"
# (apt retire winehq-stable, en conflit) ; garde-fou : dpkg --compare-versions "$v" ge 11.6.
COPY --chmod=755 upgrade-wine.sh /usr/local/bin/vigie-upgrade-wine
RUN /usr/local/bin/vigie-upgrade-wine "${WINE_VERSION}" "${WINE_DEBIAN_SUITE}" "${WINE_PACKAGE_REVISION}" "${WINEHQ_REPO_FINGERPRINT}"; \
    rm -rf /tmp/* /var/tmp/*

# Python Windows « embarquable » + bibliothèques, PRÉINSTALLÉS dans l'image (aucune installation au
# démarrage, aucun installeur Windows exécuté sous Wine). Les paquets Windows (wheels win_amd64) sont
# installés depuis Linux par `pip --target --platform win_amd64`. Le pont RPyC « classic » (port 8001)
# tourne dans ce Python sous Wine et expose le module MetaTrader5 à Vigie (rpyc.classic.connect).
ARG WIN_PYTHON_VERSION=3.11.9
ARG WIN_PYTHON_TAG=311
ARG RPYC_VERSION=6.0.2
RUN set -eux; \
    d=/opt/winpython; mkdir -p "$d"; \
    curl -fsSL --retry 3 "https://www.python.org/ftp/python/${WIN_PYTHON_VERSION}/python-${WIN_PYTHON_VERSION}-embed-amd64.zip" -o /tmp/py.zip; \
    python3 -m zipfile -e /tmp/py.zip "$d"; rm -f /tmp/py.zip; \
    pth="$d/python${WIN_PYTHON_TAG}._pth"; test -f "$pth"; \
    printf 'python%s.zip\r\n.\r\nLib\\site-packages\r\nimport site\r\n' "${WIN_PYTHON_TAG}" > "$pth"; \
    python3 -m pip install --no-cache-dir --break-system-packages --no-warn-conflicts \
        --target "$d/Lib/site-packages" --platform win_amd64 --python-version "${WIN_PYTHON_VERSION%.*}" \
        --implementation cp --only-binary=:all: MetaTrader5 "rpyc==${RPYC_VERSION}" python-dateutil; \
    test -d "$d/Lib/site-packages/MetaTrader5"; test -d "$d/Lib/site-packages/rpyc"; \
    ls "$d/Lib/site-packages" | grep -i dist-info > /Metatrader/winpython-packages.txt; \
    chmod -R a+rX "$d"
COPY --chmod=644 vigie_bridge.py /opt/winpython/vigie_bridge.py

# Démarrage : /Metatrader/start.sh (chemin inscrit dans /config/.config/openbox/autostart des volumes
# existants) remplace le script d'origine : préfixe Wine, installation de MT5 si absent (sans blocage
# sur l'installeur), lancement du terminal, puis pont RPyC surveillé et relancé s'il s'arrête.
# Journal : /config/vigie-mt5.log. Le script d'origine reste disponible sous /Metatrader/start-upstream.sh.
RUN mv /Metatrader/start.sh /Metatrader/start-upstream.sh && chmod 755 /Metatrader/start-upstream.sh
COPY --chmod=755 start.sh /Metatrader/start.sh

EXPOSE 3000 8001
VOLUME /config
