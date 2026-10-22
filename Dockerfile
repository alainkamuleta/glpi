# =============================================================================
# D3X — Image GLPI de production, construite depuis notre fork (alainkamuleta/glpi)
# =============================================================================
# Build multi-étage :
#   1. builder  : installe composer + node + extensions PHP, compile GLPI
#                 (composer install --no-dev + npm build + locales)
#   2. runtime  : image slim php:8.4-apache, ne contient que l'application
#                 compilée + les extensions d'exécution.
# =============================================================================

# -----------------------------------------------------------------------------
# Étape 1 — Compilation
# -----------------------------------------------------------------------------
FROM php:8.4-cli AS builder

ARG NODE_VERSION=22.11.0

# Dépendances système nécessaires au build (dont `patch` pour les post-install
# de composer, et les libs des extensions PHP compilées).
RUN apt-get update && apt-get install -y --no-install-recommends \
        git \
        unzip \
        patch \
        libzip-dev \
        libpng-dev \
        libjpeg62-turbo-dev \
        libfreetype6-dev \
        libicu-dev \
        libonig-dev \
        libxml2-dev \
        libcurl4-openssl-dev \
        libldap2-dev \
        libbz2-dev \
        libssl-dev \
        zlib1g-dev \
        libpq-dev \
    && rm -rf /var/lib/apt/lists/*

# Extensions PHP requises par GLPI (composer.json `require.ext-*` + dépendances
# de l'outillage de build). Certaines (ctype, json, openssl, etc.) sont déjà
# incluses dans PHP 8.4 ; on installe explicitement les autres.
RUN docker-php-ext-configure gd --with-freetype --with-jpeg \
    && docker-php-ext-install -j"$(nproc)" \
        bcmath \
        curl \
        exif \
        gd \
        gettext \
        intl \
        ldap \
        mbstring \
        mysqli \
        opcache \
        pdo \
        pdo_mysql \
        pdo_pgsql \
        sockets \
        zip \
    && docker-php-ext-enable opcache

# Composer (copié depuis l'image officielle composer:2)
COPY --from=composer:2 /usr/bin/composer /usr/bin/composer

# Node.js (binaire officiel, requis >= 20.9 pour le build webpack de GLPI)
RUN curl -fsSL "https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-x64.tar.xz" \
    | tar -xJ -C /usr/local --strip-components=1 --no-same-owner \
    && node --version \
    && npm --version

WORKDIR /var/www/glpi

# Copie du source (vendor/, node_modules/, .git exclus par .dockerignore)
COPY . .

# Build complet de GLPI : équivalent de la procédure officielle
#   php bin/console dependencies install
# qui enchaîne composer install + npm install + npm run build + locales compile.
RUN php bin/console dependencies install --allow-superuser \
    && rm -rf node_modules .git tests .github

# -----------------------------------------------------------------------------
# Étape 2 — Image d'exécution
# -----------------------------------------------------------------------------
FROM php:8.4-apache

# Dépendances d'exécution (libs des extensions, sans les outils de build)
RUN apt-get update && apt-get install -y --no-install-recommends \
        libicu74 \
        libpng16-16 \
        libjpeg62-turbo \
        libfreetype6 \
        libcurl4 \
        libldap2 \
        libzip4 \
        libonig5 \
        libpq5 \
        ca-certificates \
        curl \
    && rm -rf /var/lib/apt/lists/*

# Mêmes extensions que le builder (nécessaires au runtime de GLPI)
RUN docker-php-ext-configure gd --with-freetype --with-jpeg \
    && docker-php-ext-install -j"$(nproc)" \
        bcmath \
        curl \
        exif \
        gd \
        gettext \
        intl \
        ldap \
        mbstring \
        mysqli \
        opcache \
        pdo \
        pdo_mysql \
        pdo_pgsql \
        sockets \
        zip \
    && docker-php-ext-enable opcache

# Modules Apache nécessaires
RUN a2enmod rewrite headers

# DocumentRoot : GLPI 11 sert depuis public/
ENV APACHE_DOCUMENT_ROOT=/var/www/glpi/public
RUN sed -ri -e 's!/var/www/html!${APACHE_DOCUMENT_ROOT}!g' \
        /etc/apache2/sites-available/*.conf \
        /etc/apache2/apache2.conf \
        /etc/apache2/conf-available/*.conf

# Copie de l'application compilée depuis le builder
COPY --from=builder --chown=www-data:www-data /var/www/glpi /var/www/glpi

# Sauvegarde de la structure initiale de files/ (répertoires _cache, _uploads,
# etc.) afin de pouvoir (ré)initialiser un volume vide au premier démarrage.
RUN cp -a /var/www/glpi/files /var/www/glpi-files-init

# Volumes de persistance (config/, files/, plugins/)
VOLUME /var/www/glpi/config
VOLUME /var/www/glpi/files
VOLUME /var/www/glpi/plugins

# Entrypoint custom : initialise les volumes au premier lancement puis
# enchaîne sur l'entrypoint Apache du parent (docker-php-entrypoint).
COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
RUN chmod +x /usr/local/bin/docker-entrypoint.sh

WORKDIR /var/www/glpi

ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
CMD ["apache2-foreground"]
