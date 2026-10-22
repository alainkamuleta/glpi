# =============================================================================
# D3X — Image MariaDB dédiée pour GLPI
# =============================================================================
# Image dédiée pour la base de données de GLPI, basée sur MariaDB 11.8
# (même version que le docker-compose officiel de développement GLPI) avec une
# configuration optimisée (utf8mb4, InnoDB, timeouts adaptés aux gros tickets).
# =============================================================================
FROM mariadb:11.8

# Configuration MariaDB dédiée GLPI (charset utf8mb4 + tuning)
COPY my.cnf /etc/mysql/conf.d/99-glpi.cnf
