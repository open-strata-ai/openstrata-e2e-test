-- OpenStrata service databases (created once at Postgres init).
-- Flyway / SQLAlchemy handle table creation; here we only create
-- databases and users so each service can connect and run migrations.

CREATE USER admin     WITH PASSWORD 'admin';
CREATE USER billing   WITH PASSWORD 'billing';
CREATE USER srs       WITH PASSWORD 'srs';
CREATE USER platform  WITH PASSWORD 'platform';
CREATE USER eval_user WITH PASSWORD 'eval';

CREATE DATABASE admin_gov     OWNER admin;
CREATE DATABASE billing       OWNER billing;
CREATE DATABASE srs           OWNER srs;
CREATE DATABASE platform_api  OWNER platform;
CREATE DATABASE eval          OWNER eval_user;
