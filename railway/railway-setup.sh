#!/bin/bash
set -e

# -> Run entrypoint
# somehow when specify custom cmd in railway,
# it doesn't run entrypoint first, so we need to run it here.
sudo /usr/local/bin/railway-entrypoint.sh

echo "-> Configure bench with Railway services"
# Railway Redis services require authentication and have auto-generated hostnames.
# We must configure bench to use the correct REDIS_URL (with auth) instead of
# the default FRAPPE_REDIS_* env vars (which don't include auth).
# These REDIS_URL vars are set by Railway's Redis plugin automatically.

cat > /home/frappe/bench/sites/common_site_config.json << SITECONFIG
{
  "db_host": "${FRAPPE_DB_HOST}",
  "db_port": 3306,
  "redis_cache": "${REDIS_CACHE_URL}",
  "redis_queue": "${REDIS_QUEUE_URL}",
  "redis_socketio": "${REDIS_QUEUE_URL}",
  "socketio_port": 9000,
  "use_redis_auth": true
}
SITECONFIG

echo "-> Config created:"
cat /home/frappe/bench/sites/common_site_config.json

echo "-> Unset FRAPPE_REDIS_* to prevent overriding config"
unset FRAPPE_REDIS_CACHE
unset FRAPPE_REDIS_QUEUE

echo "-> Create new site with ERPNext"
bench new-site ${RFP_DOMAIN_NAME} \
  --admin-password ${RFP_SITE_ADMIN_PASSWORD} \
  --db-root-username root \
  --db-root-password ${RFP_DB_ROOT_PASSWORD} \
  --mariadb-user-host-login-scope='%' \
  --install-app erpnext

bench use ${RFP_DOMAIN_NAME}

echo "-> Install Frappe CRM"
bench --site ${RFP_DOMAIN_NAME} install-app crm

echo "-> Enable scheduler"
bench enable-scheduler

echo "-> Setup complete!"
