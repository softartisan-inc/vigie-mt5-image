# vigie-mt5-image

Image Docker du **terminal MetaTrader 5** utilisé par Vigie : MetaTrader 5 sous Wine, accès web noVNC sur le port 3000, pont RPyC sur le port 8001.

Ce dépôt est **public** pour profiter des minutes GitHub Actions gratuites. Il ne contient que la recette de l'image : aucun identifiant de courtier, aucune clé, aucun code de trading. L'image publiée reste **privée** sur GHCR.

## Pourquoi une image construite à part

Sur le serveur, construire Wine 11 prend 30 à 45 minutes, à cause de la lenteur du dépôt WineHQ. GitHub construit la même image en quelques minutes. Coolify n'a plus qu'à la télécharger.

Wine ≥ 11.6 est obligatoire : la build actuelle de `terminal64.exe` s'arrête sur « A debugger has been found running in your system » sous Wine 10 (bug Wine 58043).

## Contenu

| Fichier | Rôle |
|---|---|
| `Dockerfile` | dérive de `gmag11/metatrader5_vnc:2.3` (épinglée) et remplace Wine stable par WineHQ devel (`ARG WINE_VERSION`) |
| `upgrade-wine.sh` | mise à niveau de Wine ; retient une version publiée à la fois en amd64 et en i386, ≥ 11.6 ; n'échoue jamais, résultat dans `/Metatrader/wine-upgrade.log` (`STATUS=ok` ou `STATUS=failed` + `RAISON=`) |
| `start.sh` | démarrage complet (remplace le script d'origine) : préfixe Wine, installation de MT5 si absent (installeur arrêté dès que `terminal64.exe` existe), terminal, puis pont RPyC surveillé et relancé ; journal `/config/vigie-mt5.log` |
| `vigie_bridge.py` | pont RPyC « classic » (port 8001) exécuté par le Python Windows préinstallé dans `/opt/winpython` (Python 3.11 embarquable + `MetaTrader5` + `rpyc`, installés à la construction) |
| `workflow/mt5-image.yml` | modèle du workflow GitHub Actions, à copier dans `.github/workflows/mt5-image.yml` |

## Images publiées

- `ghcr.io/softartisan-inc/vigie-mt5:wine-<WINE_VERSION>` : utilisée par `docker-compose.yml` de Vigie ;
- `ghcr.io/softartisan-inc/vigie-mt5:sha-<commit>` : traçabilité.

Le workflow échoue si l'image ne contient pas `STATUS=ok`, c'est-à-dire si Wine n'a pas été mis à niveau.

## Installer le workflow (une seule fois)

Les outils d'automatisation n'ont pas le droit de créer un workflow :

1. Sur GitHub, *Add file* → *Create new file*.
2. Nommez le fichier `.github/workflows/mt5-image.yml`.
3. Collez-y le contenu de `workflow/mt5-image.yml`.
4. *Commit changes* sur `main`.

Le workflow se lance ensuite à chaque modification de `Dockerfile`, `start.sh` ou `upgrade-wine.sh` sur `main` (une modification de `vigie_bridge.py` seule demande un lancement manuel, ou l'ajout de ce fichier aux `paths` du workflow). On peut aussi le lancer à la main : *Actions* → « Image MT5 » → *Run workflow*.

## Source de référence

La référence reste `docker/mt5/` dans le dépôt privé `softartisan-inc/vigie-trading`. Toute modification s'y fait d'abord, puis elle est recopiée ici à l'identique.

## Utiliser l'image depuis le serveur

L'image est privée. Le serveur a donc besoin d'un jeton GitHub avec la portée `read:packages` :

```bash
echo '<jeton>' | docker login ghcr.io -u <identifiant-github> --password-stdin
docker pull ghcr.io/softartisan-inc/vigie-mt5:wine-11.10
```
