#!/bin/bash
# EC2 only (Week 12 box 3). The shared initdb SQL (01-create-service-roles.sql)
# still creates order_service_user / inventory_service_user with the local dev
# passwords plus every schema/ownership/grant; this runs AFTER it (02 > 01 in
# the entrypoint's alphabetical order) and overrides just those two passwords
# with the real values from infra/ec2.env, so a real, distinct secret is
# honoured instead of the hardcoded dev values.
#
# The entrypoint runs init scripts against a temporary server with local trust,
# so `psql -U "$POSTGRES_USER"` connects without a password here, exactly like
# the .sql scripts do. Fail loudly if either password is unset.
if [ -z "$ORDER_SERVICE_PASSWORD" ] || [ -z "$INVENTORY_SERVICE_PASSWORD" ]; then
    echo "02-service-roles-passwords.sh: ORDER_SERVICE_PASSWORD and INVENTORY_SERVICE_PASSWORD must both be set" >&2
    exit 1
fi

# psql substitutes :'var' only in a script/stdin, NOT in -c strings, so the two
# ALTERs are fed through a quoted heredoc (no shell expansion) with ON_ERROR_STOP.
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" \
  -v order_pw="$ORDER_SERVICE_PASSWORD" \
  -v inventory_pw="$INVENTORY_SERVICE_PASSWORD" <<-'EOSQL'
ALTER ROLE order_service_user WITH LOGIN PASSWORD :'order_pw';
ALTER ROLE inventory_service_user WITH LOGIN PASSWORD :'inventory_pw';
EOSQL
