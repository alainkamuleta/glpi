#!/usr/bin/env bash
# =============================================================================
# D3X — deploy_glpi.sh
# =============================================================================
# Construit notre image GLPI (à partir du fork) et l'image MariaDB dédiée,
# puis déploie la stack Docker sur la machine cible (sonde-01).
#
# Usage :
#   ./deploy_glpi.sh [PORT] [--rebuild]
#
#   PORT        : port hôte exposé (défaut 8080).
#   --rebuild   : force un rebuild sans cache des images.
#
# Le script lit un fichier `.env` local (non versionné) pour les mots de passe
# DB ; s'il est absent, il en génère et l'écrit. C'est conforme à la règle #6 :
# le code est versionné, les secrets restent hors de git.
# =============================================================================
set -euo pipefail

# --- Résolution du répertoire de déploiement (là où le script vit) -----------
DEPLOY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$DEPLOY_DIR"

# --- Port exposé -------------------------------------------------------------
PORT="${1:-${GLPI_PORT:-8080}}"
shift || true
REBUILD=0
for arg in "$@"; do
    case "$arg" in
        --rebuild) REBUILD=1 ;;
    esac
done

# --- Adresse de bind (LAN + WireGuard pour accès VPN) ------------------------
BIND_IP="${GLPI_BIND_IP:-0.0.0.0}"

# --- Secrets DB : génération si .env absent ----------------------------------
ENV_FILE="$DEPLOY_DIR/.env"
if [[ ! -f "$ENV_FILE" ]]; then
    echo "[deploy] Aucun .env trouvé -> génération de mots de passe DB aléatoires."
    cat > "$ENV_FILE" <<EOF
# Généré automatiquement par deploy_glpi.sh — NE PAS VERSIONNER (règle #6)
GLPI_DB_ROOT_PASSWORD=$(openssl rand -hex 24)
GLPI_DB_PASSWORD=$(openssl rand -hex 24)
GLPI_PORT=${PORT}
GLPI_BIND_IP=${BIND_IP}
EOF
    chmod 600 "$ENV_FILE"
    echo "[deploy] Fichier .env créé (permissions 600)."
else
    echo "[deploy] .env existant utilisé."
fi

# Chargement du .env (parsing robuste, valeurs avec caractères spéciaux)
set -a
while IFS='=' read -r key value; do
    [[ -z "$key" || "$key" == \#* ]] && continue
    printf -v "$key" '%s' "$value"
done < "$ENV_FILE"
set +a

# Surcharge du port/bind par la ligne de commande
export GLPI_PORT="$PORT"
export GLPI_BIND_IP="$BIND_IP"

# --- Vérification des prérequis ----------------------------------------------
if ! command -v docker >/dev/null 2>&1; then
    echo "[deploy] ERREUR : docker est introuvable sur cette machine." >&2
    exit 1
fi
if ! docker compose version >/dev/null 2>&1; then
    echo "[deploy] ERREUR : docker compose (v2) est requis." >&2
    exit 1
fi

echo "======================================================"
echo " Déploiement GLPI D3X"
echo "   Port hôte     : ${PORT}"
echo "   Bind IP       : ${BIND_IP}"
echo "   Répertoire    : ${DEPLOY_DIR}"
echo "======================================================"

# --- Build des images --------------------------------------------------------
if [[ "$REBUILD" -eq 1 ]]; then
    echo "[deploy] Rebuild complet (--no-cache) des images GLPI + DB..."
    docker compose build --no-cache
else
    echo "[deploy] Build des images GLPI + DB (cache si possible)..."
    docker compose build
fi

# --- Démarrage de la stack ---------------------------------------------------
echo "[deploy] Démarrage de la stack (glpi-app + glpi-db)..."
docker compose up -d

# --- Attente de la santé des conteneurs --------------------------------------
echo "[deploy] Attente de la disponibilité des services..."
ATTEMPTS=0
MAX_ATTEMPTS=60   # 60 x 10s = 10 minutes max
until docker compose ps --format '{{.Name}} {{.Health}}' | grep -q 'glpi-app.*healthy' \
      || [[ $ATTEMPTS -ge $MAX_ATTEMPTS ]]; do
    sleep 10
    ATTEMPTS=$((ATTEMPTS + 1))
    echo "[deploy]   ... en attente (${ATTEMPTS}/${MAX_ATTEMPTS})"
done

echo "[deploy] État des conteneurs :"
docker compose ps

# --- Affichage de l'URL ------------------------------------------------------
echo ""
echo "======================================================"
echo " GLPI déployé. Accès :"
echo "   LAN        : http://192.168.1.41:${PORT}"
echo "   WireGuard  : http://10.0.88.41:${PORT}"
echo ""
echo " À la première connexion, GLPI lancera son assistant"
echo " d'installation (choisir la base 'glpi' sur l'hôte"
echo " 'glpi-db' avec l'utilisateur 'glpi' et le mot de"
echo " passe contenu dans ${ENV_FILE})."
echo "======================================================"
