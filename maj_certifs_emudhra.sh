#!/usr/bin/env bash
# Corrige pip, certifi, ca-certificates, conda, Homebrew et uv suite à
# l'incident eMudhra/emSign (octobre 2026).
#
# Les wheels pip/certifi sont téléchargées puis vérifiées par SHA-256 avant
# usage ; les installations pip se font ensuite hors ligne (--no-index).
# conda est forcé d'utiliser le cacert.pem du certifi vérifié (CONDA_SSL_VERIFY)
# pour ne pas dépendre de son propre bundle, potentiellement vulnérable.
# Homebrew vérifie lui-même ses bottles (API signée + SHA-256).
#
# Usage : ./maj_certifs_emudhra.sh [--dry-run] [--yes] [--sans-conda] [--sans-brew]

set -euo pipefail

PIP_WHL=pip-26.2.2-py3-none-any.whl
PIP_URL=https://files.pythonhosted.org/packages/3f/06/3e4420302363fbb71be3c7f35ce042f54bfca330e3e66b3a2e3c4cca579f/$PIP_WHL
PIP_SHA=fd7f4dfa8190e014013b9f08f3e973f4e4c26ffd179a204895533a7254813a70

CERTIFI_WHL=certifi-2026.10.19-py3-none-any.whl
CERTIFI_URL=https://files.pythonhosted.org/packages/c4/51/29046e48f693c54e5b7412216d447a1d8362c9653148d98c02cdf65fa733/$CERTIFI_WHL
CERTIFI_SHA=42d35340cc5b9ba78e818ddbff0c5b1c2b779de448a340fd1b989f5fa8670e1b

MIN_PIP=26.2.2
MIN_CERTIFI=2026.10.19
MIN_CACERTS=2026.10.19
MIN_CONDA=26.9.4
MIN_UV=0.13.4

DRY_RUN=0
YES=0
DO_CONDA=1
DO_BREW=1
for arg in "$@"; do
  case $arg in
    --dry-run)    DRY_RUN=1 ;;
    --yes|-y)     YES=1 ;;
    --sans-conda) DO_CONDA=0 ;;
    --sans-brew)  DO_BREW=0 ;;
    *) echo "Option inconnue : $arg" >&2; exit 2 ;;
  esac
done

run() {
  echo "  \$ $*"
  if (( ! DRY_RUN )); then "$@"; fi
}

confirm() {
  (( YES || DRY_RUN )) && return 0
  local rep
  read -r -p "  $1 [o/N] " rep
  [[ $rep == [oOyY]* ]]
}

# Vrai si la version $1 est strictement inférieure à $2
ver_lt() {
  [[ $1 != "$2" && $(printf '%s\n%s\n' "$1" "$2" | sort -V | head -1) == "$1" ]]
}

WARNINGS=()
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# 1. Téléchargement + vérification des wheels
echo "== Téléchargement et vérification des wheels"
fetch() {
  local url=$1 file=$2 sha=$3
  curl -fsSL -o "$WORK/$file" "$url"
  if [[ $(shasum -a 256 "$WORK/$file" | cut -d' ' -f1) != "$sha" ]]; then
    echo "ÉCHEC : SHA-256 incorrect pour $file — arrêt (possible interception)." >&2
    exit 1
  fi
  echo "  OK $file"
}
fetch "$PIP_URL" "$PIP_WHL" "$PIP_SHA"
fetch "$CERTIFI_URL" "$CERTIFI_WHL" "$CERTIFI_SHA"

unzip -p "$WORK/$CERTIFI_WHL" certifi/cacert.pem > "$WORK/cacert.pem"

# 2. Environnements conda
update_conda() {
  local BASE_PY ENVS prefix py py_ver py_ok name channel version cert
  BASE_PY="$(conda info --base)/bin/python"
  export CONDA_SSL_VERIFY="$WORK/cacert.pem"

  # Affiche "nom canal version" des paquets suivis dans un environnement
  pkg_info() {
    conda list -p "$1" --json | "$BASE_PY" -I -c '
import json, sys
for p in json.load(sys.stdin):
    if p["name"] in ("pip", "certifi", "ca-certificates", "conda"):
        print(p["name"], p["channel"], p["version"])'
  }

  ENVS=$(conda env list --json | "$BASE_PY" -I -c 'import json,sys; print("\n".join(json.load(sys.stdin)["envs"]))')

  while IFS= read -r prefix; do
    [[ -n $prefix ]] || continue
    echo
    echo "== conda : $prefix"
    py="$prefix/bin/python"
    if [[ ! -x $py ]]; then
      echo "  pas de Python, ignoré"
      continue
    fi
    py_ver=$("$py" -I -c 'import sys; print("%d.%d" % sys.version_info[:2])')
    py_ok=$("$py" -I -c 'import sys; print(int(sys.version_info >= (3, 10)))')
    echo "  Python $py_ver"

    local conda_specs=("ca-certificates>=$MIN_CACERTS")
    local pip_wheels=() fallback_wheels=() conda_spec=""
    while read -r name channel version; do
      case $name in
        certifi)
          if [[ $channel == pypi ]]; then pip_wheels+=("$WORK/$CERTIFI_WHL")
          else
            conda_specs+=("$channel::certifi>=$MIN_CERTIFI")
            fallback_wheels+=("$WORK/$CERTIFI_WHL")
          fi ;;
        pip)
          (( py_ok )) || continue
          if [[ $channel == pypi ]]; then pip_wheels+=("$WORK/$PIP_WHL")
          else
            conda_specs+=("$channel::pip>=$MIN_PIP")
            fallback_wheels+=("$WORK/$PIP_WHL")
          fi ;;
        conda)
          # Upgraded on its own: conda 26.9.4 needs Python >= 3.11 and must not
          # block the CA packages and pip, which are what actually matters.
          conda_spec="$channel::conda>=$MIN_CONDA" ;;
      esac
    done < <(pkg_info "$prefix")

    # certifi absent mais pip présent : on installe certifi pour le pip.conf ci-dessous
    if (( ! py_ok )) && ! "$py" -I -c 'import certifi' 2>/dev/null; then
      pip_wheels+=("$WORK/$CERTIFI_WHL")
    fi

    local opts=()
    (( YES )) && opts+=(-y)
    (( DRY_RUN )) && opts+=(--dry-run)
    # conda est toujours lancé : en simulation, son --dry-run affiche le plan
    echo "  \$ conda install -p $prefix ${opts[*]-} ${conda_specs[*]}"
    # A failing env (inconsistent, unsatisfiable…) must not stop the others.
    # pip < 26.2.2 stays vulnerable whatever conda does, so fall back to the
    # verified wheels, even over conda's own pip/certifi.
    if ! conda install -p "$prefix" "${opts[@]+"${opts[@]}"}" "${conda_specs[@]}"; then
      if (( ${#fallback_wheels[@]} )); then
        pip_wheels+=("${fallback_wheels[@]}")
        WARNINGS+=("$prefix : conda install a échoué, pip/certifi remplacés par les wheels vérifiées (conda les listera comme pypi).")
      else
        WARNINGS+=("$prefix : conda install a échoué (voir ci-dessus), ca-certificates non mis à jour.")
      fi
    fi
    if (( ${#pip_wheels[@]} )); then
      if ! run "$py" -I -m pip install --no-index --no-deps --upgrade "${pip_wheels[@]}"; then
        WARNINGS+=("$prefix : installation des wheels pip/certifi échouée (voir ci-dessus).")
      fi
    fi
    if [[ -n $conda_spec ]]; then
      echo "  \$ conda install -p $prefix ${opts[*]-} $conda_spec"
      if ! conda install -p "$prefix" "${opts[@]+"${opts[@]}"}" "$conda_spec"; then
        WARNINGS+=("$prefix : conda non mis à jour vers $MIN_CONDA (Python $py_ver ?). Sans risque si ca-certificates et certifi sont à jour.")
      fi
    fi

    # Python < 3.10 : pip 26.2.2 indisponible. Un pip ancien (sans truststore)
    # remplace son bundle intégré par celui donné via "cert" : on le pointe sur
    # le certifi à jour de l'environnement, via le pip.conf propre à l'env.
    if (( ! py_ok )); then
      if (( DRY_RUN )); then
        echo "  (écrirait $prefix/pip.conf avec cert = <cacert.pem du certifi de l'env>)"
      else
        cert=$("$py" -I -c 'import certifi; print(certifi.where())')
        printf '[global]\ncert = %s\n' "$cert" > "$prefix/pip.conf"
        echo "  pip.conf écrit : cert = $cert"
      fi
      WARNINGS+=("$prefix : Python $py_ver, pip reste ancien (pip.conf pointe vers le certifi à jour). À migrer vers Python >= 3.10.")
    fi
  done <<< "$ENVS"

  echo
  echo "== conda : contrôle"
  while IFS= read -r prefix; do
    py="$prefix/bin/python"
    [[ -x $py ]] || continue
    printf '  %-45s ' "$prefix"
    "$py" -I -c '
import importlib.metadata as m
def v(p):
    try: return m.version(p)
    except Exception: return "-"
print("pip", v("pip"), "| certifi", v("certifi"))' 2>/dev/null || echo "?"
  done <<< "$ENVS"
}

# 3. Homebrew (Python, certifi, ca-certificates, uv)
update_brew() {
  local installed formulae=() f py v pip_v
  echo
  echo "== Homebrew"
  run brew update
  installed=$(brew list --formula)
  for f in ca-certificates certifi uv; do
    grep -qx "$f" <<< "$installed" && formulae+=("$f")
  done
  while IFS= read -r f; do formulae+=("$f"); done < <(grep -E '^python@3\.[0-9]+$' <<< "$installed" || true)

  # Sans cela, brew mettrait aussi à jour tous les dépendants (llvm, mysql,
  # node…), y compris des changements de version majeure sans rapport.
  export HOMEBREW_NO_INSTALLED_DEPENDENTS_CHECK=1

  if (( ${#formulae[@]} )); then
    if (( DRY_RUN )); then
      echo "  \$ brew upgrade --dry-run ${formulae[*]}"
      brew upgrade --dry-run "${formulae[@]}"
    elif confirm "Mettre à jour ${formulae[*]} ?"; then
      run brew upgrade "${formulae[@]}"
    else
      WARNINGS+=("Homebrew : mise à jour refusée.")
    fi
  fi

  # Le pip des Python Homebrew vit dans $(brew --prefix)/lib/pythonX.Y et ne
  # suit pas forcément la formule : on le corrige avec la wheel vérifiée.
  while IFS= read -r f; do
    v=${f#python@}
    py="$(brew --prefix)/bin/python$v"
    [[ -x $py ]] || continue
    # Version of the pip module actually imported: importlib.metadata may pick a
    # stale pip-X.dist-info left next to the one linked by brew.
    pip_v=$("$py" -I -c 'import pip; print(pip.__version__)' 2>/dev/null || echo "")
    if [[ -z $pip_v ]]; then
      echo "  python$v : pas de pip"
    elif ! "$py" -I -c 'import sys; sys.exit(sys.version_info < (3, 10))'; then
      WARNINGS+=("Homebrew python$v : Python < 3.10, pip $pip_v ne peut pas être corrigé.")
    elif ver_lt "$pip_v" "$MIN_PIP"; then
      echo "  python$v : pip $pip_v → $MIN_PIP"
      run "$py" -I -m pip install --no-index --no-deps --upgrade --break-system-packages "$WORK/$PIP_WHL"
    else
      echo "  python$v : pip $pip_v OK"
    fi
  done < <(grep -E '^python@3\.[0-9]+$' <<< "$installed" || true)
}

# 4. uv (hors Homebrew : auto-mise à jour avec le magasin de certificats système)
update_uv() {
  local uv_path uv_v
  uv_path=$(command -v uv) || return 0
  uv_v=$(uv --version | awk '{print $2}')
  echo
  echo "== uv : $uv_path ($uv_v)"
  if ! ver_lt "$uv_v" "$MIN_UV"; then
    echo "  OK"
  elif [[ $uv_path == "$(brew --prefix 2>/dev/null)"/* ]]; then
    if (( DRY_RUN )); then echo "  (sera mis à jour par brew upgrade uv)"
    else WARNINGS+=("uv $uv_v toujours < $MIN_UV après brew upgrade."); fi
  else
    UV_SYSTEM_CERTS=true run uv self update
  fi
}

if (( DO_CONDA )); then
  if command -v conda >/dev/null; then update_conda
  else echo "conda introuvable, ignoré"; fi
fi
if (( DO_BREW )); then
  if command -v brew >/dev/null; then update_brew
  else echo "brew introuvable, ignoré"; fi
fi
update_uv

echo
for w in "${WARNINGS[@]+"${WARNINGS[@]}"}"; do echo "ATTENTION : $w"; done
(( DRY_RUN )) && echo "(simulation : rien n'a été modifié)"
exit 0
