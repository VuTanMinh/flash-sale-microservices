DO $roles$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'order_service_user') THEN
    CREATE ROLE order_service_user LOGIN PASSWORD 'order_service_dev';
  ELSE
    ALTER ROLE order_service_user WITH LOGIN PASSWORD 'order_service_dev';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'inventory_service_user') THEN
    CREATE ROLE inventory_service_user LOGIN PASSWORD 'inventory_service_dev';
  ELSE
    ALTER ROLE inventory_service_user WITH LOGIN PASSWORD 'inventory_service_dev';
  END IF;
END
$roles$;

GRANT CONNECT ON DATABASE flashsale TO order_service_user, inventory_service_user;

CREATE SCHEMA IF NOT EXISTS order_service AUTHORIZATION order_service_user;
ALTER SCHEMA order_service OWNER TO order_service_user;
CREATE SCHEMA IF NOT EXISTS inventory_service AUTHORIZATION inventory_service_user;
ALTER SCHEMA inventory_service OWNER TO inventory_service_user;

DO $ownership$
DECLARE
  obj RECORD;
BEGIN
  FOR obj IN
    SELECT schemaname, tablename,
      CASE schemaname
        WHEN 'public' THEN 'order_service_user'
        WHEN 'order_service' THEN 'order_service_user'
        WHEN 'inventory_service' THEN 'inventory_service_user'
      END AS owner_name
    FROM pg_tables
    WHERE schemaname IN ('public', 'order_service', 'inventory_service')
  LOOP
    EXECUTE format('ALTER TABLE %I.%I OWNER TO %I', obj.schemaname, obj.tablename, obj.owner_name);
  END LOOP;

  FOR obj IN
    SELECT sequence_schema, sequence_name,
      CASE sequence_schema
        WHEN 'public' THEN 'order_service_user'
        WHEN 'order_service' THEN 'order_service_user'
        WHEN 'inventory_service' THEN 'inventory_service_user'
      END AS owner_name
    FROM information_schema.sequences
    WHERE sequence_schema IN ('public', 'order_service', 'inventory_service')
  LOOP
    EXECUTE format('ALTER SEQUENCE %I.%I OWNER TO %I', obj.sequence_schema, obj.sequence_name, obj.owner_name);
  END LOOP;
END
$ownership$;
REVOKE ALL ON SCHEMA public FROM PUBLIC, inventory_service_user;
GRANT USAGE, CREATE ON SCHEMA public TO order_service_user;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO order_service_user;
GRANT USAGE, SELECT, UPDATE ON ALL SEQUENCES IN SCHEMA public TO order_service_user;
ALTER DEFAULT PRIVILEGES FOR ROLE flashsale IN SCHEMA public
  GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO order_service_user;
ALTER DEFAULT PRIVILEGES FOR ROLE flashsale IN SCHEMA public
  GRANT USAGE, SELECT, UPDATE ON SEQUENCES TO order_service_user;
REVOKE ALL ON SCHEMA inventory_service FROM order_service_user, PUBLIC;
REVOKE ALL ON SCHEMA order_service FROM inventory_service_user, PUBLIC;
