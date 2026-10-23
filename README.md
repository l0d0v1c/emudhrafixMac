# maj_certifs_emudhra.sh

Script macOS qui corrige pip, certifi, ca-certificates, conda, Homebrew et uv
suite à l'incident de sécurité eMudhra / emSign d'octobre 2026.

## Le problème

Huit clés privées de CA intermédiaires eMudhra/emSign étaient trivialement
faibles (chaque clé était un entier inférieur à 256). N'importe qui peut donc
fabriquer un certificat TLS valide pour n'importe quel domaine, y compris
pypi.org ou python.org, et intercepter les connexions (attaque de l'homme du
milieu).

Les navigateurs et les systèmes d'exploitation ont bloqué ces certificats,
mais **pip utilise toujours son propre certifi intégré**, en plus du magasin
du système, sans possibilité de le désactiver. Un pip antérieur à 26.2.2 fait
donc encore confiance aux clés compromises, même sur un macOS à jour, et
pourrait installer un paquet piégé.

Versions corrigées :

| Outil | Version minimale |
|---|---|
| pip | 26.2.2 |
| certifi | 2026.10.19 |
| ca-certificates (conda) | 2026.10.19 |
| conda | 26.9.4 |
| uv | 0.13.4 |

## Ce que fait le script

1. **Télécharge les wheels pip 26.2.2 et certifi 2026.10.19 et vérifie leur
   SHA-256.** Les empreintes attendues sont inscrites dans le script. En cas
   d'écart, le script s'arrête (possible interception).
2. **Environnements conda** (base et tous les autres) :
   - conda utilise le `cacert.pem` du certifi vérifié (`CONDA_SSL_VERIFY`) au
     lieu de son bundle, potentiellement vulnérable ;
   - `ca-certificates`, `certifi` et `pip` sont mis à jour, plus `conda` dans
     base ; un paquet installé par conda est mis à jour par conda, un paquet
     installé par pip est remplacé par la wheel vérifiée, installée hors ligne
     (`--no-index`) ;
   - pour un environnement en Python < 3.10, où pip 26.2.2 ne s'installe pas,
     certifi est mis à jour et un `pip.conf` propre à l'environnement oblige
     l'ancien pip à utiliser ce certifi à jour au lieu de son bundle intégré.
3. **Homebrew** :
   - `brew upgrade` limité à `ca-certificates`, `certifi`, `uv` et aux
     `python@3.x` installés ;
   - les paquets qui en dépendent ne sont **pas** mis à jour
     (`HOMEBREW_NO_INSTALLED_DEPENDENTS_CHECK=1`), pour éviter des mises à jour
     majeures sans rapport (mysql, node, llvm…) ;
   - le pip de chaque Python Homebrew est contrôlé ensuite et, s'il est
     antérieur à 26.2.2, remplacé par la wheel vérifiée.
4. **uv** : mis à jour par brew s'il vient de Homebrew, sinon par
   `UV_SYSTEM_CERTS=true uv self update`.
5. **Contrôle final** : affiche les versions de pip et certifi de chaque
   environnement conda, puis les éventuels avertissements.

## Utilisation

```sh
chmod +x maj_certifs_emudhra.sh
./maj_certifs_emudhra.sh --dry-run      # simulation : affiche le plan, ne modifie rien
./maj_certifs_emudhra.sh                # demande confirmation (conda, puis brew)
./maj_certifs_emudhra.sh --yes          # sans confirmation
```

| Option | Effet |
|---|---|
| `--dry-run` | Simulation. conda et brew affichent ce qu'ils feraient. |
| `--yes`, `-y` | Ne demande aucune confirmation. |
| `--sans-conda` | Ignore la partie conda. |
| `--sans-brew` | Ignore la partie Homebrew. |

Lancez d'abord `--dry-run` et relisez le plan, surtout pour l'environnement
base de conda, où la mise à jour vers conda 26.9.4 ajoute et retire quelques
dépendances.

## Prérequis

- macOS avec `bash`, `curl`, `shasum`, `unzip`, `sort -V` (présents par défaut) ;
- conda et/ou Homebrew : une partie absente est simplement ignorée.

## Limites

- **Python < 3.10** (conda ou Homebrew) : pip ne peut pas passer en 26.2.2.
  Pour conda, le `pip.conf` est une parade non testée ; la vraie solution est
  de migrer l'environnement vers Python ≥ 3.10.
- **Le `/usr/bin/python3` d'Apple (Python 3.9)** n'est pas traité : ne
  l'utilisez pas pour installer des paquets.
- **Ne sont pas traités** : les virtualenvs hors conda (`python -m venv`,
  Poetry, environnements créés par uv…), pipx, les Python gérés par uv ou
  pyenv, et les images Docker. Il faut mettre à jour pip et certifi dans
  chacun, et reconstruire les images sans cache.
- **Lockfiles** (`requirements.txt`, `poetry.lock`, `uv.lock`…) : une version
  figée de certifi doit être relevée à la main.
- **Hors Python** : le `/usr/bin/curl` de macOS et Node.js peuvent continuer à
  faire confiance aux certificats compromis.
- **Dépendants Homebrew** : laissés à jour plus tard via un `brew upgrade`
  complet. Attention à mysql, dont la version majeure change.
- Les empreintes SHA-256 et les versions minimales sont figées dans le script ;
  modifiez les variables en tête de fichier pour une version plus récente.

## Sources

- [Discussion officielle Python (discuss.python.org)](https://discuss.python.org/t/information-for-python-users-regarding-emudhra-emsign-ca-certificate-security-incident/109576)
- [BleepingComputer](https://bleepingcomputer.com/news/security/mozilla-google-apple-block-compromised-emudhra-ca-certificates)
- [The Hacker News](https://thehackernews.com/2026/10/eight-emudhra-ca-keys-compromised.html)
- [Bugzilla Mozilla](https://bugzilla.mozilla.org/show_bug.cgi?id=2018979)
- [lilting.ch (tests curl, Node.js et uv sur macOS)](https://lilting.ch/en/articles/emudhra-weak-intermediate-ca-keys)
