#!/usr/bin/env bash
# Entrypoint de l'image GLPI D3X.
# Initialise les volumes de persistance au premier démarrage, corrige les
# permissions, puis délègue à l'entrypoint Apache du parent.
set -euo pipefail

echo "[glpi-entrypoint] Initialisation des volumes de persistance..."

# --- files/ : répertoires de travail GLPI (_cache, _uploads, _sessions, ...) ---
# Si le volume monté est vide (premier lancement), on y copie la structure
# initiale sauvegardée dans l'image.
if [ ! -d /var/www/glpi/files/_cache ]; then
    echo "[glpi-entrypoint] Volume files/ vide -> copie de la structure initiale."
    cp -a /var/www/glpi-files-init/. /var/www/glpi/files/
fi

# --- plugins/ : préserver le .gitkeep si le volume est vide ---
if [ ! -e /var/www/glpi/plugins/.gitkeep ] && [ -z "$(ls -A /var/www/glpi/plugins 2>/dev/null)" ]; then
    echo "[glpi-entrypoint] Volume plugins/ vide -> initialisation."
    touch /var/www/glpi/plugins/.gitkeep
fi

# --- permissions : tout doit appartenir à www-data ---
chown -R www-data:www-data /var/www/glpi/files /var/www/glpi/config /var/www/glpi/plugins
chmod -R u+rwX,g+rwX /var/www/glpi/files /var/www/glpi/config /var/www/glpi/plugins

echo "[glpi-entrypoint] Initialisation terminée, démarrage d'Apache."

# Enchaînement sur l'entrypoint de l'image parent (gère le drop de privilèges,
# les APACHE_* variables d'environnement, etc.)
exec docker-php-entrypoint "$@"
