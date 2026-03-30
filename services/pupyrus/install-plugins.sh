#!/usr/bin/env bash
set -euo pipefail

# Copy composer files from image to bind mount (picks up changes on rebuild)
cp /usr/src/composer/composer.json /usr/src/composer/composer.lock /var/www/html/

# Install plugins into wp-content/plugins/
cd /var/www/html
composer install --no-dev --no-interaction --prefer-dist --no-progress

# Hand off to Apache
exec apache2-foreground
