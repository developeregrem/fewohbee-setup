#!/bin/sh
set -e

# -------------------------------------------------------
# fewohbee interactive setup
# Reads .env.dist from /config (mount),
# asks a few questions, generates passwords and writes
# .env ready for "docker compose up -d".
# -------------------------------------------------------

echo ""
echo "=== fewohbee Setup ==="
echo ""

# ---- sanity checks ----
if [ -f "/config/.env" ]; then
    echo "Configuration already exists (.env found). Remove it to reconfigure."
    exit 0
fi

if [ ! -f "/config/.env.dist" ]; then
    echo "Error: .env.dist not found in the mounted directory."
    echo ""
    echo "Make sure to run this container from the fewohbee-dockerized directory:"
    echo "  Linux/Mac:  docker run --rm -it -v \$(pwd):/config developeregrem/fewohbee-setup"
    echo "  Windows PS: docker run --rm -it -v \${PWD}:/config developeregrem/fewohbee-setup"
    exit 1
fi

# ---- copy template to tmp ----
umask 0177
cp /config/.env.dist /tmp/.env.tmp

# ---- hostname ----
hostname_default="localhost"
printf "Server hostname [%s]: " "$hostname_default"
read -r pveHost
pveHost="${pveHost:-$hostname_default}"

sed "s/HOST_NAME=fewohbee/HOST_NAME=$pveHost/" /tmp/.env.tmp > /tmp/.env.tmp2 && mv /tmp/.env.tmp2 /tmp/.env.tmp
sed "s/RELYING_PARTY_ID=example.com/RELYING_PARTY_ID=$pveHost/" /tmp/.env.tmp > /tmp/.env.tmp2 && mv /tmp/.env.tmp2 /tmp/.env.tmp

# ---- SSL ----
ssl=""
while ! printf '%s' "$ssl" | grep -qE "^(self-signed|letsencrypt|reverse-proxy)$"; do
    printf "SSL mode (self-signed/letsencrypt/reverse-proxy) [self-signed]: "
    read -r ssl
    ssl="${ssl:-self-signed}"
done

if [ "$ssl" = "letsencrypt" ]; then
    printf "Email address for Let's Encrypt notifications: "
    read -r leMail

    leDomains="$pveHost"
    printf "Also add www subdomain (www.%s)? (yes/no) [yes]: " "$pveHost"
    read -r leWww
    leWww="${leWww:-yes}"
    if [ "$leWww" = "yes" ]; then
        leDomains="$leDomains www.$pveHost"
    fi

    sed 's@LETSENCRYPT=false@LETSENCRYPT=true@g' /tmp/.env.tmp > /tmp/.env.tmp2 && mv /tmp/.env.tmp2 /tmp/.env.tmp
    sed 's@SELF_SIGNED=true@SELF_SIGNED=false@g' /tmp/.env.tmp > /tmp/.env.tmp2 && mv /tmp/.env.tmp2 /tmp/.env.tmp
    sed "s@LETSENCRYPT_DOMAINS=\"<domain.tld>\"@LETSENCRYPT_DOMAINS=\"$leDomains\"@g" /tmp/.env.tmp > /tmp/.env.tmp2 && mv /tmp/.env.tmp2 /tmp/.env.tmp
    sed "s@EMAIL=\"<your mail address>\"@EMAIL=\"$leMail\"@g" /tmp/.env.tmp > /tmp/.env.tmp2 && mv /tmp/.env.tmp2 /tmp/.env.tmp
fi

# reverse-proxy: SSL is handled externally — disable both SSL options in .env
# and switch to the no-ssl compose file
if [ "$ssl" = "reverse-proxy" ]; then
    sed 's@SELF_SIGNED=true@SELF_SIGNED=false@g' /tmp/.env.tmp > /tmp/.env.tmp2 && mv /tmp/.env.tmp2 /tmp/.env.tmp
    sed 's@COMPOSE_FILE=docker-compose.yml@COMPOSE_FILE=docker-compose.no-ssl.yml@g' /tmp/.env.tmp > /tmp/.env.tmp2 && mv /tmp/.env.tmp2 /tmp/.env.tmp
fi

# ---- app mode ----
pveEnv=""
while ! printf '%s' "$pveEnv" | grep -qE "^(prod|dev)$"; do
    printf "Run mode (prod/dev) [prod]: "
    read -r pveEnv
    pveEnv="${pveEnv:-prod}"
done

# prod uses redis caching
if [ "$pveEnv" = "prod" ]; then
    pveEnv="redis"
fi
sed "s@APP_ENV=prod@APP_ENV=$pveEnv@g" /tmp/.env.tmp > /tmp/.env.tmp2 && mv /tmp/.env.tmp2 /tmp/.env.tmp

# ---- language ----
pveLang=""
while ! printf '%s' "$pveLang" | grep -qE "^(de|en)$"; do
    printf "Language (de/en) [de]: "
    read -r pveLang
    pveLang="${pveLang:-de}"
done
sed "s@LOCALE=de@LOCALE=$pveLang@g" /tmp/.env.tmp > /tmp/.env.tmp2 && mv /tmp/.env.tmp2 /tmp/.env.tmp

# ---- generate secrets & passwords ----
echo ""
echo "Generating passwords and secrets ..."

mariadbRootPw=$(openssl rand -hex 20)
mariadbPw=$(openssl rand -hex 20)
mysqlBackupPw=$(openssl rand -hex 20)
appSecret=$(openssl rand -base64 23)

sed "s@MARIADB_ROOT_PASSWORD=<pw>@MARIADB_ROOT_PASSWORD=$mariadbRootPw@g" /tmp/.env.tmp > /tmp/.env.tmp2 && mv /tmp/.env.tmp2 /tmp/.env.tmp
sed "s@MARIADB_PASSWORD=<pw>@MARIADB_PASSWORD=$mariadbPw@g" /tmp/.env.tmp > /tmp/.env.tmp2 && mv /tmp/.env.tmp2 /tmp/.env.tmp
sed "s@MYSQL_BACKUP_PASSWORD=<backuppassword>@MYSQL_BACKUP_PASSWORD=$mysqlBackupPw@g" /tmp/.env.tmp > /tmp/.env.tmp2 && mv /tmp/.env.tmp2 /tmp/.env.tmp
sed "s@APP_SECRET=<secret>@APP_SECRET=$appSecret@g" /tmp/.env.tmp > /tmp/.env.tmp2 && mv /tmp/.env.tmp2 /tmp/.env.tmp
sed "s@db_password@$mariadbPw@g" /tmp/.env.tmp > /tmp/.env.tmp2 && mv /tmp/.env.tmp2 /tmp/.env.tmp

# ---- write final file ----
mv /tmp/.env.tmp /config/.env

echo ""
echo "==================================="
echo " Setup complete!"
echo "==================================="
echo ""
echo "File created: .env"
echo ""
echo "Next steps:"
echo ""
echo "  1. Optionally review and adjust .env"
echo ""
echo "  2. Start the application:"
echo "       docker compose up -d"
if [ "$ssl" = "reverse-proxy" ]; then
    echo ""
    echo "     Configure your reverse proxy to forward requests to port \${LISTEN_PORT} (default: 80)."
fi
echo ""
echo "  3. Wait for the application to finish setup (git clone + composer, ~2 min)."
echo "     You can monitor progress with: docker compose logs -f php"
echo "     Once you see 'ready to handle connections', run the following command once"
echo "     to initialize the application (creates the first admin user, loads base templates,"
echo "     and optionally loads sample data):"
echo ""
echo "       docker compose exec --user www-data php sh -c 'php fewohbee/bin/console app:first-run'"
echo ""
if [ "$ssl" = "reverse-proxy" ]; then
    printf "  Application will be available at: http://%s (via reverse proxy)\n" "$pveHost"
else
    printf "  Application will be available at: https://%s\n" "$pveHost"
    if [ "$ssl" = "self-signed" ]; then
        echo "  (Accept the browser security warning on first visit - self-signed certificate)"
    fi
fi
echo ""
