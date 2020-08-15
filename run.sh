#!/bin/bash

set -x

sudo docker volume create openstreetmap-data

function createPostgresImportConfig() {
    cp /etc/postgresql/12/main/postgresql.import.conf.tmpl /etc/postgresql/12/main/conf.d/postgresql.import.conf
    sudo -u postgres echo "autovacuum = $AUTOVACUUM" >> /etc/postgresql/12/main/conf.d/postgresql.import.conf
    cat /etc/postgresql/12/main/conf.d/postgresql.import.conf
}

function createPostgresStartConfig() {
    cp /etc/postgresql/12/main/postgresql.custom.conf.tmpl /etc/postgresql/12/main/conf.d/postgresql.custom.conf
    sudo -u postgres echo "autovacuum = $AUTOVACUUM" >> /etc/postgresql/12/main/conf.d/postgresql.custom.conf
    cat /etc/postgresql/12/main/conf.d/postgresql.custom.conf
}

function setPostgresPassword() {
    sudo -u postgres psql -c "ALTER USER renderer PASSWORD '${PGPASSWORD:-renderer}'"
}

STARTTIMEGLOBAL=$(date +%s)

# ######################################################
echo "############  SET DATABASE DIRECTORY  ############"
# ######################################################

STARTTIME=$(date +%s)

chown postgres:postgres -R /var/lib/postgresql
if [ ! -f /var/lib/postgresql/12/main/PG_VERSION ]; then
    sudo -u postgres /usr/lib/postgresql/12/bin/pg_ctl -D /var/lib/postgresql/12/main/ initdb -o "--locale C.UTF-8"
fi

# ######################################################
echo "############  CONFIG POSTGRESQL  #################"
# ######################################################

export AUTOVACUUM=off
createPostgresImportConfig

# ######################################################
echo "############  INITIALIZE POSTGRESQL  #############"
# ######################################################

service postgresql start
sudo -u postgres createuser renderer
sudo -u postgres createdb -E UTF8 -O renderer gis
sudo -u postgres psql -d gis -c "CREATE EXTENSION postgis;"
sudo -u postgres psql -d gis -c "CREATE EXTENSION hstore;"
sudo -u postgres psql -d gis -c "ALTER TABLE geometry_columns OWNER TO renderer;"
sudo -u postgres psql -d gis -c "ALTER TABLE spatial_ref_sys OWNER TO renderer;"
setPostgresPassword

ENDTIME=$(date +%s)
echo "INFO: initialize finished: $(($ENDTIME - $STARTTIME)) seconds"

# ######################################################
echo "############  DOWNLOAD DATA  #####################"
# ######################################################

STARTTIME=$(date +%s)

FILE_DATA=/data.osm.pbf
if test -f "$FILE_DATA"; then
    echo "$FILE_DATA exists."
else
    echo "INFO: Download PBF file: $DOWNLOAD_PBF"
    wget -nv "$DOWNLOAD_PBF" -O $FILE_DATA
fi

FILE_POLY=/data.poly
if test -f "$FILE_POLY"; then
    echo "$FILE_POLY exists."
else
    echo "INFO: Download PBF-POLY file: $DOWNLOAD_POLY"
    wget -nv "$DOWNLOAD_POLY" -O $FILE_POLY
fi

ENDTIME=$(date +%s)
echo "INFO: download data finished: $(($ENDTIME - $STARTTIME)) seconds"

# ######################################################
echo "############  IMPORT DATA  #######################"
# ######################################################

STARTTIME=$(date +%s)

sudo -u renderer cp /data.poly /var/lib/mod_tile/data.poly
sudo -u renderer osm2pgsql -d gis --create --slim -G --hstore --tag-transform-script /home/renderer/src/openstreetmap-carto/openstreetmap-carto.lua --number-processes ${THREADS:-4} -S /home/renderer/src/openstreetmap-carto/openstreetmap-carto.style /data.osm.pbf ${OSM2PGSQL_EXTRA_ARGS}
sudo -u postgres psql -d gis -f indexes.sql
touch /var/lib/mod_tile/planet-import-complete

ENDTIME=$(date +%s)
echo "INFO: import data finished: $(($ENDTIME - $STARTTIME)) seconds"

STARTTIME=$(date +%s)

service postgresql stop
rm /data.osm.pbf
rm -rf /tmp/*

ENDTIME=$(date +%s)
echo "INFO: clean finished: $(($ENDTIME - $STARTTIME)) seconds"

# ######################################################
echo "#####  INITIALIZE POSTGRESQL & APACHE  ###########"
# ######################################################

STARTTIME=$(date +%s)

chown postgres:postgres /var/lib/postgresql -R
export AUTOVACUUM=on
createPostgresStartConfig
service postgresql start
service apache2 restart
setPostgresPassword

# ######################################################
echo "############  CONFIGURE THREADS  #################"
# ######################################################

sed -i -E "s/num_threads=[0-9]+/num_threads=${THREADS:-4}/g" /usr/local/etc/renderd.conf

# ######################################################
echo "############  CONFIGURE RUN  #####################"
# ######################################################

stop_handler() {
    kill -TERM "$child"
}
trap stop_handler SIGTERM

sudo -u renderer renderd -f -c /usr/local/etc/renderd.conf &
child=$!

ENDTIME=$(date +%s)
echo "INFO: start finished: $(($ENDTIME - $STARTTIME)) seconds"

ENDTIMEGLOBAL=$(date +%s)
echo "INFO: process finished: $(($ENDTIMEGLOBAL - $STARTTIMEGLOBAL)) seconds"

wait "$child"

service postgresql stop

# ######################################################
echo "############  POSTGRESQL STOP  ###################"
# ######################################################

exit 0
