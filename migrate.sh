#!/bin/bash

# Script untuk migrasi database production (volume + image) ke server lain
# tanpa dump DB. Data volume disalin apa adanya (file-level).
#
# Default export berjalan ONLINE (tanpa downtime):
#   - MySQL      -> CLONE LOCAL DATA DIRECTORY (plugin clone MySQL 8.0)
#   - PostgreSQL -> pg_basebackup
# Keduanya menghasilkan salinan data directory yang konsisten selagi database
# tetap melayani read/write. Opsi --offline menghentikan container sebentar.
#
# Usage:
#   ./migrate.sh export [output_dir] [--offline]   # di server lama
#   ./migrate.sh import <bundle.tar> [--force] [--no-start]   # di server baru
#   ./migrate.sh push <user@server-baru> [--remote-dir DIR] [--source-ip IP] [--check] [--force]
#       -> dijalankan di server lama: migrasi langsung via SSH/Tailscale, tanpa
#          file di disk server lama, server baru langsung di-setup & dijalankan
#
# Hasil export: satu file migration-<timestamp>.tar berisi:
#   images.tar          -> semua image dari docker-compose.yml (docker save)
#   volumes/*.tar.gz    -> isi setiap named volume
#   project.tar.gz      -> .env, docker-compose.yml, mysql/, postgres/, script
#   manifest.env        -> info project, daftar volume & image
#   SHA256SUMS          -> checksum untuk verifikasi

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

COMPOSE_FILE="docker-compose.yml"
NETWORK_NAME="infra_net"
# Image helper untuk tar volume. Pakai postgres:15 (sudah ada di compose) agar
# tidak perlu pull image tambahan dan tetap jalan di server tanpa internet.
HELPER_IMAGE="postgres:15"
# Volume yang bisa dibackup online -> nama service pemiliknya
declare -A ONLINE_SERVICE=( [mysql_prod_data]=mysql [postgres_prod_data]=postgres )
# Lokasi sementara salinan online di dalam container (dihapus setelah selesai)
MYSQL_CLONE_DIR="/tmp/migrate-clone"
PG_BASE_DIR="/tmp/migrate-pgbase"

usage() {
    sed -n '3,24p' "$0" | sed 's/^# \{0,1\}//'
    exit 1
}

project_name() {
    local name=""
    if [ -f .env ]; then
        name="$(grep -E '^COMPOSE_PROJECT_NAME=' .env | tail -1 | cut -d= -f2- | tr -d '"'"'"' \r')"
    fi
    if [ -z "$name" ]; then
        name="$(basename "$SCRIPT_DIR" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9_-')"
    fi
    echo "$name"
}

containers_running() {
    docker compose -f "$COMPOSE_FILE" ps -q 2>/dev/null | grep -q .
}

env_value() {
    # Ambil nilai mentah; kutip hanya dibuang kalau membungkus seluruh nilai
    local v
    v="$(grep -E "^$1=" .env | tail -1 | cut -d= -f2- | tr -d '\r')"
    if [[ "$v" =~ ^\"(.*)\"$ || "$v" =~ ^\'(.*)\'$ ]]; then v="${BASH_REMATCH[1]}"; fi
    printf '%s' "$v"
}

# Ambil direktori dari dalam container lewat `docker cp` (tidak butuh tar di
# image tersebut) lalu kemas ulang jadi <vol>.tar.gz dengan owner asli.
pack_container_dir() {
    local ctr="$1" dir="$2" vol="$3" out="$4"
    docker cp "$ctr:$dir" - | docker run --rm -i \
        -v "$out":/backup \
        "$HELPER_IMAGE" \
        sh -c "mkdir /x && tar --numeric-owner -xpf - --strip-components=1 -C /x && tar --numeric-owner -czf /backup/$vol.tar.gz -C /x ."
}

backup_mysql_online() {
    local ctr="$1" vol="$2" out="$3" root_pw installed
    root_pw="$(env_value MYSQL_ROOT_PASSWORD)"
    local mysql=(docker exec -e MYSQL_PWD="$root_pw" "$ctr" mysql -uroot -N -B)

    installed="$("${mysql[@]}" -e "SELECT COUNT(*) FROM information_schema.plugins WHERE plugin_name='clone'")"
    if [ "$installed" = 0 ]; then
        "${mysql[@]}" -e "INSTALL PLUGIN clone SONAME 'mysql_clone.so'"
    fi

    # Plugin clone hanya menyalin isi tabel InnoDB; engine lain jadi kosong
    local others
    others="$("${mysql[@]}" -e "SELECT CONCAT(table_schema,'.',table_name,' (',engine,')') FROM information_schema.tables
        WHERE engine IS NOT NULL AND engine <> 'InnoDB'
        AND table_schema NOT IN ('mysql','sys','information_schema','performance_schema')")"
    if [ -n "$others" ]; then
        echo "⚠️  Tabel non-InnoDB berikut TIDAK ikut tersalin isinya oleh clone:"
        echo "$others" | sed 's/^/     - /'
        echo "   Ubah ke InnoDB (ALTER TABLE ... ENGINE=InnoDB) atau pakai --offline."
    fi

    docker exec "$ctr" rm -rf "$MYSQL_CLONE_DIR"
    "${mysql[@]}" -e "CLONE LOCAL DATA DIRECTORY = '$MYSQL_CLONE_DIR'"
    pack_container_dir "$ctr" "$MYSQL_CLONE_DIR" "$vol" "$out"
    docker exec "$ctr" rm -rf "$MYSQL_CLONE_DIR"

    if [ "$installed" = 0 ]; then
        "${mysql[@]}" -e "UNINSTALL PLUGIN clone"
    fi
}

backup_postgres_online() {
    local ctr="$1" vol="$2" out="$3"
    docker exec "$ctr" rm -rf "$PG_BASE_DIR"
    docker exec -u postgres -e PGPASSWORD="$(env_value POSTGRES_PASSWORD)" "$ctr" \
        pg_basebackup -U "$(env_value POSTGRES_USER)" -D "$PG_BASE_DIR" -Fp -X stream -c fast
    pack_container_dir "$ctr" "$PG_BASE_DIR" "$vol" "$out"
    docker exec "$ctr" rm -rf "$PG_BASE_DIR"
}

backup_volume_cold() {
    local full="$1" vol="$2" out="$3"
    docker run --rm \
        -v "$full":/data:ro \
        -v "$out":/backup \
        "$HELPER_IMAGE" \
        tar --numeric-owner -czf "/backup/$vol.tar.gz" -C /data .
}

do_export() {
    local out_dir="" offline=0
    for arg in "$@"; do
        case "$arg" in
            --offline) offline=1 ;;
            *) out_dir="$arg" ;;
        esac
    done
    out_dir="${out_dir:-$SCRIPT_DIR/migration-backups}"
    local project ts work bundle mode
    was_running=0
    project="$(project_name)"
    ts="$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$out_dir"
    out_dir="$(cd "$out_dir" && pwd)"
    work="$out_dir/migration-$ts"
    bundle="$out_dir/migration-$ts.tar"
    mkdir -p "$work/volumes"

    echo "📦 Export migrasi project '$project'"

    local volumes images
    volumes="$(docker compose -f "$COMPOSE_FILE" config --volumes)"
    images="$(docker compose -f "$COMPOSE_FILE" config --images | sort -u)"

    # Pastikan semua image ada secara lokal
    for img in $images; do
        if ! docker image inspect "$img" >/dev/null 2>&1; then
            echo "⬇️  Image $img belum ada, pulling..."
            docker pull "$img"
        fi
    done

    mode="online"
    [ "$offline" = 1 ] && mode="offline"
    echo "ℹ️  Mode backup: $mode"

    # Mode offline: stop container agar file database konsisten
    if [ "$offline" = 1 ] && containers_running; then
        was_running=1
        echo "⏸️  Menghentikan container sementara agar data konsisten..."
        docker compose -f "$COMPOSE_FILE" stop
    fi
    # Pastikan container dijalankan lagi walaupun export gagal di tengah jalan
    trap '[ "$was_running" = 1 ] && { echo "▶️  Menjalankan kembali container..."; docker compose -f "$COMPOSE_FILE" start; }' EXIT

    for vol in $volumes; do
        local full="${project}_${vol}"
        if ! docker volume inspect "$full" >/dev/null 2>&1; then
            echo "⚠️  Volume $full tidak ditemukan, dilewati"
            continue
        fi
        local svc="${ONLINE_SERVICE[$vol]:-}" ctr=""
        [ -n "$svc" ] && ctr="$(docker compose -f "$COMPOSE_FILE" ps -q --status running "$svc" 2>/dev/null)"
        if [ -n "$ctr" ]; then
            echo "💾 Backup ONLINE volume $full (service $svc, tanpa downtime)..."
            case "$svc" in
                mysql) backup_mysql_online "$ctr" "$vol" "$work/volumes" ;;
                postgres) backup_postgres_online "$ctr" "$vol" "$work/volumes" ;;
            esac
        else
            echo "💾 Backup volume $full ..."
            backup_volume_cold "$full" "$vol" "$work/volumes"
        fi
    done

    # Volume sudah aman, container bisa langsung jalan lagi
    if [ "$was_running" = 1 ]; then
        echo "▶️  Menjalankan kembali container..."
        docker compose -f "$COMPOSE_FILE" start
        was_running=0
    fi

    echo "🐳 Menyimpan image: $(echo $images)"
    # shellcheck disable=SC2086
    docker save -o "$work/images.tar" $images

    echo "📁 Menyimpan file project (.env, compose, config)..."
    tar --exclude='./.git' --exclude='./migration-backups' \
        --exclude="./$(basename "$out_dir")" \
        --exclude='./migration-*.tar' --exclude='./.migrate-import.*' \
        -czf "$work/project.tar.gz" -C "$SCRIPT_DIR" .

    cat > "$work/manifest.env" <<EOF
PROJECT_NAME=$project
CREATED_AT=$ts
BACKUP_MODE=$mode
SOURCE_HOST=$(hostname)
VOLUMES="$(echo $volumes)"
IMAGES="$(echo $images)"
EOF

    (cd "$work" && find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum > SHA256SUMS)

    tar -cf "$bundle" -C "$out_dir" "migration-$ts"
    rm -rf "$work"

    echo ""
    echo "✅ Export selesai: $bundle ($(du -h "$bundle" | cut -f1))"
    echo ""
    echo "📤 Kirim ke server baru, contoh:"
    echo "   scp $bundle user@server-baru:/path/tujuan/"
    echo "📥 Lalu di server baru:"
    echo "   ./migrate.sh import migration-$ts.tar"
}

do_import() {
    local bundle="" force=0 start=1
    for arg in "$@"; do
        case "$arg" in
            --force) force=1 ;;
            --no-start) start=0 ;;
            *) bundle="$arg" ;;
        esac
    done
    [ -n "$bundle" ] && [ -f "$bundle" ] || { echo "❌ File bundle tidak ditemukan: ${bundle:-<kosong>}"; usage; }
    bundle="$(cd "$(dirname "$bundle")" && pwd)/$(basename "$bundle")"

    tmp="$(mktemp -d "$SCRIPT_DIR/.migrate-import.XXXXXX")"
    trap 'rm -rf "$tmp"' EXIT

    echo "📂 Extract bundle..."
    tar -xf "$bundle" -C "$tmp"
    local work
    work="$(find "$tmp" -mindepth 1 -maxdepth 1 -type d -name 'migration-*' | head -1)"
    [ -n "$work" ] || { echo "❌ Isi bundle tidak valid"; exit 1; }

    echo "🔐 Verifikasi checksum..."
    (cd "$work" && sha256sum -c --quiet SHA256SUMS) || { echo "❌ Checksum tidak cocok, file mungkin rusak saat transfer"; exit 1; }

    # shellcheck disable=SC1091
    source "$work/manifest.env"
    echo "ℹ️  Project: $PROJECT_NAME | dari host: $SOURCE_HOST | dibuat: $CREATED_AT"

    # Cek volume tujuan sebelum melakukan perubahan apa pun
    for vol in $VOLUMES; do
        local full="${PROJECT_NAME}_${vol}"
        if docker volume inspect "$full" >/dev/null 2>&1 && [ "$force" != 1 ]; then
            echo "❌ Volume $full sudah ada di server ini. Gunakan --force untuk menimpa isinya."
            exit 1
        fi
    done

    echo "🐳 Load image..."
    docker load -i "$work/images.tar"

    echo "📁 Restore file project ke $SCRIPT_DIR ..."
    if [ -f "$SCRIPT_DIR/.env" ] && [ "$force" != 1 ]; then
        echo "   .env sudah ada, file project yang sudah ada TIDAK ditimpa (pakai --force untuk menimpa)"
        tar -xzf "$work/project.tar.gz" -C "$SCRIPT_DIR" --skip-old-files
    else
        tar -xzf "$work/project.tar.gz" -C "$SCRIPT_DIR"
    fi

    if containers_running; then
        echo "⏸️  Menghentikan container yang sedang berjalan..."
        docker compose -f "$COMPOSE_FILE" down
    fi

    for vol in $VOLUMES; do
        local full="${PROJECT_NAME}_${vol}"
        [ -f "$work/volumes/$vol.tar.gz" ] || { echo "⚠️  Backup $vol tidak ada di bundle, dilewati"; continue; }
        if ! docker volume inspect "$full" >/dev/null 2>&1; then
            # Label agar docker compose mengenali volume ini sebagai miliknya
            docker volume create \
                --label "com.docker.compose.project=$PROJECT_NAME" \
                --label "com.docker.compose.volume=$vol" \
                "$full" >/dev/null
        fi
        echo "💾 Restore volume $full ..."
        docker run --rm \
            -v "$full":/data \
            -v "$work/volumes":/backup:ro \
            "$HELPER_IMAGE" \
            sh -c "find /data -mindepth 1 -delete && tar --numeric-owner -xpzf /backup/$vol.tar.gz -C /data"
    done

    if ! docker network inspect "$NETWORK_NAME" >/dev/null 2>&1; then
        echo "🌐 Membuat network $NETWORK_NAME ..."
        docker network create "$NETWORK_NAME" >/dev/null
    fi

    if [ "$start" = 1 ]; then
        echo "🚀 Menjalankan container..."
        docker compose -f "$COMPOSE_FILE" up -d
        docker compose -f "$COMPOSE_FILE" ps
    fi

    echo ""
    echo "✅ Import selesai. Data, image, dan konfigurasi sudah dipindahkan."
}

# ---------------------------------------------------------------------------
# push: migrasi langsung server lama -> server baru lewat SSH (mis. Tailscale).
# Tidak ada file yang ditulis di disk server lama: image di-stream lewat SSH,
# data PostgreSQL & MySQL ditarik server baru langsung dari database yang
# sedang berjalan (pg_basebackup & CLONE INSTANCE).
# ---------------------------------------------------------------------------

# Script remote selalu diawali ini: masuk ke folder project & load .env
# (.env dibaca baris per baris, bukan di-source, supaya password berisi
# karakter khusus seperti ' ! $ tidak rusak)
REMOTE_PRELUDE='set -euo pipefail; mkdir -p "$1"; cd "$1"; shift
if [ -f .env ]; then
    while IFS= read -r l || [ -n "$l" ]; do
        l="${l%$'"'"'\r'"'"'}"; k="${l%%=*}"; v="${l#*=}"
        [[ "$l" == *=* && "$k" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
        if [[ "$v" =~ ^\"(.*)\"$ || "$v" =~ ^\'"'"'(.*)\'"'"'$ ]]; then v="${BASH_REMATCH[1]}"; fi
        export "$k=$v"
    done < .env
fi'
HBA_MARKER="# migrate.sh push"

rrun() {
    local script="$1" args="" a
    shift
    for a in "$REMOTE_DIR" "$@"; do args+=" $(printf %q "$a")"; done
    # Dibungkus { } agar bash membaca seluruh script sebelum dijalankan, lalu
    # stdin diputus supaya `docker compose exec` tidak memakan sisa script
    ssh "${SSH_OPTS[@]}" "$TARGET" "bash -s --$args" <<<"{ exec </dev/null
$REMOTE_PRELUDE
$script
}"
}

db_env_hash() {
    grep -E '^(MYSQL_|POSTGRES_|COMPOSE_PROJECT_NAME=)' | tr -d '\r' | sort | sha256sum | cut -c1-16
}

local_mysql() {
    docker exec -e MYSQL_PWD="$(env_value MYSQL_ROOT_PASSWORD)" "$OLD_MYSQL" mysql -uroot -N -B -e "$1"
}

local_psql() {
    docker exec "$OLD_PG" psql -U "$(env_value POSTGRES_USER)" -d "${2:-$(env_value POSTGRES_DB)}" -tAc "$1"
}

push_cleanup() {
    local rc=$?
    set +e
    if [ "${HBA_ADDED:-0}" = 1 ]; then
        docker exec "$OLD_PG" bash -c "sed -i '/$HBA_MARKER\$/d' \"\$PGDATA/pg_hba.conf\""
        local_psql "SELECT pg_reload_conf()" >/dev/null
        echo "🧹 Izin replikasi sementara di server lama dicabut"
    fi
    if [ "${CLONE_PLUGIN_ADDED:-0}" = 1 ]; then
        local_mysql "UNINSTALL PLUGIN clone" && echo "🧹 Plugin clone di server lama dicopot"
    fi
    ssh "${SSH_OPTS[@]}" -O exit "$TARGET" 2>/dev/null
    [ "$rc" != 0 ] && echo "❌ Migrasi gagal. Server lama tidak berubah; perbaiki masalahnya lalu ulangi dengan --force."
    exit "$rc"
}

# Tunggu MySQL di server baru selesai init dan menerima koneksi jaringan
# (saat init, entrypoint menjalankan server sementara dengan skip_networking)
REMOTE_WAIT_MYSQL='for i in $(seq 100); do
    if [ "$(docker compose exec -T -e MYSQL_PWD="$MYSQL_ROOT_PASSWORD" mysql \
          mysql -uroot -N -B -e "SELECT @@skip_networking" 2>/dev/null)" = 0 ]; then exit 0; fi
    sleep 3
done
echo "MySQL di server baru tidak kunjung siap" >&2; exit 1'

# Clone MySQL server lama ($1:$2) ke MySQL server baru
read -r -d '' REMOTE_CLONE_MYSQL <<'EOF_CLONE' || true
pw="${MYSQL_ROOT_PASSWORD//\'/\'\'}"
r() { docker compose exec -T -e MYSQL_PWD="$MYSQL_ROOT_PASSWORD" mysql mysql -uroot -N -B -e "$1"; }
[ "$(r "SELECT COUNT(*) FROM information_schema.plugins WHERE plugin_name='clone'")" = 1 ] \
    || r "INSTALL PLUGIN clone SONAME 'mysql_clone.so'"
r "SET GLOBAL clone_valid_donor_list = '$1:$2'"
out="$(r "CLONE INSTANCE FROM 'root'@'$1':$2 IDENTIFIED BY '$pw'" 2>&1)" || true
# 3707 = clone sukses, hanya restart otomatis yang tidak didukung di Docker
if [ -n "$out" ] && ! grep -q 3707 <<<"$out"; then echo "$out" >&2; exit 1; fi
docker compose restart mysql >/dev/null 2>&1 || docker compose up -d mysql >/dev/null 2>&1
EOF_CLONE

do_push() {
    TARGET="" REMOTE_DIR="$SCRIPT_DIR"
    local source_ip="" force=0 check=0
    while [ $# -gt 0 ]; do
        case "$1" in
            --remote-dir) REMOTE_DIR="$2"; shift ;;
            --source-ip) source_ip="$2"; shift ;;
            --force) force=1 ;;
            --check) check=1 ;;
            -*) echo "❌ Opsi tidak dikenal: $1"; usage ;;
            *) TARGET="$1" ;;
        esac
        shift
    done
    [ -n "$TARGET" ] || { echo "❌ Tujuan belum diisi, contoh: ./migrate.sh push root@100.x.y.z"; usage; }

    SSH_OPTS=(-o BatchMode=yes -o ServerAliveInterval=30
              -o ControlMaster=auto -o "ControlPath=/tmp/migrate-ssh-%C" -o ControlPersist=300)
    HBA_ADDED=0 CLONE_PLUGIN_ADDED=0 OLD_MYSQL="" OLD_PG=""
    trap push_cleanup EXIT

    local project volumes images
    project="$(project_name)"
    volumes="$(docker compose -f "$COMPOSE_FILE" config --volumes)"
    images="$(docker compose -f "$COMPOSE_FILE" config --images | sort -u)"

    if [ -z "$source_ip" ] && command -v tailscale >/dev/null; then
        source_ip="$(tailscale ip -4 2>/dev/null | head -1)"
    fi
    [ -n "$source_ip" ] || { echo "❌ IP server lama tidak terdeteksi, isi dengan --source-ip <IP Tailscale server lama>"; exit 1; }

    echo "🔎 [1/7] Pengecekan"
    echo "   Server lama : $source_ip   Server baru : $TARGET:$REMOTE_DIR   Project : $project"

    OLD_MYSQL="$(docker compose -f "$COMPOSE_FILE" ps -q --status running mysql)"
    OLD_PG="$(docker compose -f "$COMPOSE_FILE" ps -q --status running postgres)"
    [ -n "$OLD_MYSQL" ] && [ -n "$OLD_PG" ] || { echo "❌ Container MySQL/PostgreSQL di server lama harus sedang berjalan"; exit 1; }
    local mysql_port pg_port
    mysql_port="$(docker compose -f "$COMPOSE_FILE" port mysql 3306 | awk -F: '{print $NF}')"
    pg_port="$(docker compose -f "$COMPOSE_FILE" port postgres 5432 | awk -F: '{print $NF}')"

    rrun 'true' 2>/dev/null || { echo "❌ SSH ke $TARGET gagal. Pasang SSH key dulu: ssh-copy-id $TARGET"; exit 1; }
    rrun 'docker info >/dev/null 2>&1 && docker compose version >/dev/null' \
        || { echo "❌ Docker/Docker Compose di server baru belum terpasang, atau user SSH tidak punya akses docker"; exit 1; }
    echo "   ✅ SSH & Docker server baru OK"

    if ! rrun '[ -f docker-compose.yml ] && [ -f .env ]'; then
        echo "   📁 Konfigurasi belum ada di server baru, mengirim file project..."
        tar --exclude='./.git' --exclude='./migration-backups' --exclude='./migration-*.tar' \
            --exclude='./.migrate-import.*' -czf - -C "$SCRIPT_DIR" . \
            | ssh "${SSH_OPTS[@]}" "$TARGET" "mkdir -p $(printf %q "$REMOTE_DIR") && tar -xzf - -C $(printf %q "$REMOTE_DIR")"
    fi
    if [ "$(db_env_hash < .env)" != "$(rrun 'cat .env' | db_env_hash)" ]; then
        echo "❌ Isi MYSQL_*/POSTGRES_*/COMPOSE_PROJECT_NAME di .env server baru berbeda dengan server lama."
        echo "   Samakan dulu (copy .env server lama ke $REMOTE_DIR/.env di server baru)."
        exit 1
    fi
    echo "   ✅ Konfigurasi .env sama"

    local port
    for port in "$mysql_port" "$pg_port"; do
        rrun 'timeout 5 bash -c "</dev/tcp/$1/$2"' "$source_ip" "$port" 2>/dev/null \
            || { echo "❌ Server baru tidak bisa akses $source_ip:$port (cek Tailscale/firewall)"; exit 1; }
    done
    echo "   ✅ Server baru bisa akses port $mysql_port & $pg_port server lama"

    local vol existing=""
    for vol in $volumes; do
        rrun 'docker volume inspect "$1" >/dev/null 2>&1' "${project}_${vol}" && existing+=" ${project}_${vol}"
    done
    if [ -n "$existing" ]; then
        if [ "$force" = 1 ]; then
            echo "   ⚠️  Volume berikut di server baru AKAN DITIMPA:$existing"
        else
            echo "❌ Volume sudah ada di server baru:$existing"
            echo "   Tambahkan --force untuk menimpa data di server baru (server lama tidak disentuh)."
            exit 1
        fi
    fi

    local others
    others="$(local_mysql "SELECT CONCAT(table_schema,'.',table_name,' (',engine,')') FROM information_schema.tables
        WHERE engine IS NOT NULL AND engine <> 'InnoDB'
        AND table_schema NOT IN ('mysql','sys','information_schema','performance_schema')")"
    if [ -n "$others" ]; then
        echo "   ⚠️  Tabel MySQL non-InnoDB berikut TIDAK ikut tersalin isinya:"
        echo "$others" | sed 's/^/        - /'
        echo "      Ubah dulu ke InnoDB: ALTER TABLE <db>.<tabel> ENGINE=InnoDB;"
        [ "$check" = 1 ] || { read -r -p "   Lanjutkan? [y/N] " ans; [ "$ans" = y ] || exit 1; }
    fi

    if [ "$check" = 1 ]; then
        echo "✅ Semua pengecekan lolos. Jalankan tanpa --check untuk mulai migrasi."
        exit 0
    fi

    echo "🐳 [2/7] Mengirim image ke server baru (stream, tanpa file)"
    local img send=""
    for img in $images; do
        if [ "$(docker image inspect -f '{{.Id}}' "$img")" = "$(rrun 'docker image inspect -f "{{.Id}}" "$1" 2>/dev/null || true' "$img")" ]; then
            echo "   ✅ $img sudah sama"
        else
            send+=" $img"
        fi
    done
    if [ -n "$send" ]; then
        echo "   ⬆️ $send"
        # shellcheck disable=SC2086
        docker save $send | gzip -1 | ssh "${SSH_OPTS[@]}" "$TARGET" "gunzip | docker load" | sed 's/^/   /'
    fi

    echo "🧰 [3/7] Menyiapkan server baru"
    rrun 'docker compose down --remove-orphans >/dev/null 2>&1 || true
        for v in "$@"; do docker volume rm "$v" >/dev/null 2>&1 || true; done
        docker network inspect "'"$NETWORK_NAME"'" >/dev/null 2>&1 || docker network create "'"$NETWORK_NAME"'" >/dev/null' \
        $(for vol in $volumes; do echo "${project}_${vol}"; done)

    echo "🐘 [4/7] Menarik data PostgreSQL (pg_basebackup, online)"
    local probe='docker run --rm -e PGPASSWORD="$POSTGRES_PASSWORD" postgres:15 \
        psql "host=$1 port=$2 user=$POSTGRES_USER dbname=postgres replication=true" -c "IDENTIFY_SYSTEM" 2>&1'
    local out client_ip
    if ! out="$(rrun "$probe" "$source_ip" "$pg_port")"; then
        client_ip="$(grep -oE 'from host "[^"]+"' <<<"$out" | head -1 | cut -d'"' -f2)"
        [ -n "$client_ip" ] || { echo "❌ Koneksi replikasi PostgreSQL gagal:"; echo "$out"; exit 1; }
        docker exec "$OLD_PG" bash -c "echo 'host replication all $client_ip/32 md5 $HBA_MARKER' >> \"\$PGDATA/pg_hba.conf\""
        HBA_ADDED=1
        local_psql "SELECT pg_reload_conf()" >/dev/null
        echo "   🔓 Izin replikasi sementara untuk $client_ip ditambahkan di server lama"
        out="$(rrun "$probe" "$source_ip" "$pg_port")" || { echo "❌ Koneksi replikasi PostgreSQL masih gagal:"; echo "$out"; exit 1; }
    fi
    rrun 'docker volume create --label com.docker.compose.project="$3" --label com.docker.compose.volume=postgres_prod_data \
            "$3_postgres_prod_data" >/dev/null
        docker run --rm -e PGPASSWORD="$POSTGRES_PASSWORD" -v "$3_postgres_prod_data":/var/lib/postgresql/data postgres:15 \
            bash -c "chown postgres:postgres /var/lib/postgresql/data && chmod 700 /var/lib/postgresql/data && \
                     gosu postgres pg_basebackup -h $1 -p $2 -U $POSTGRES_USER -D /var/lib/postgresql/data -Fp -X stream -c fast -P && \
                     sed -i \"/'"$HBA_MARKER"'\$/d\" /var/lib/postgresql/data/pg_hba.conf"' \
        "$source_ip" "$pg_port" "$project"

    echo "🐬 [5/7] Menarik data MySQL (CLONE INSTANCE, online)"
    if [ "$(local_mysql "SELECT COUNT(*) FROM information_schema.plugins WHERE plugin_name='clone'")" = 0 ]; then
        local_mysql "INSTALL PLUGIN clone SONAME 'mysql_clone.so'"
        CLONE_PLUGIN_ADDED=1
    fi
    rrun 'docker compose up -d mysql >/dev/null 2>&1'
    rrun "$REMOTE_WAIT_MYSQL"
    rrun "$REMOTE_CLONE_MYSQL" "$source_ip" "$mysql_port"
    rrun "$REMOTE_WAIT_MYSQL"
    local state
    state="$(rrun 'docker compose exec -T -e MYSQL_PWD="$MYSQL_ROOT_PASSWORD" mysql mysql -uroot -N -B \
        -e "SELECT CONCAT(state, \" \", error_no) FROM performance_schema.clone_status"')"
    [ "$state" = "Completed 0" ] || { echo "❌ Status clone MySQL: $state"; exit 1; }
    if [ "$CLONE_PLUGIN_ADDED" = 1 ]; then
        rrun 'docker compose exec -T -e MYSQL_PWD="$MYSQL_ROOT_PASSWORD" mysql mysql -uroot -e "UNINSTALL PLUGIN clone"'
    fi

    echo "🚀 [6/7] Menjalankan semua service di server baru"
    rrun 'docker compose up -d 2>&1 | grep -iv "^ *container" || true
        for i in $(seq 60); do
            docker compose exec -T postgres pg_isready -U "$POSTGRES_USER" -d "$POSTGRES_DB" >/dev/null 2>&1 && exit 0
            sleep 2
        done
        echo "PostgreSQL di server baru tidak kunjung siap" >&2; exit 1'

    echo "🔍 [7/7] Verifikasi (daftar database & jumlah tabel)"
    local q_mysql="SELECT table_schema, COUNT(*) FROM information_schema.tables
        WHERE table_schema NOT IN ('mysql','sys','information_schema','performance_schema') GROUP BY 1 ORDER BY 1"
    local q_pg_db="SELECT datname FROM pg_database WHERE NOT datistemplate ORDER BY 1"
    local q_pg_tbl="SELECT COUNT(*) FROM pg_tables WHERE schemaname NOT IN ('pg_catalog','information_schema')"
    local old_sum new_sum db
    old_sum="$(local_mysql "$q_mysql" | sed 's/^/mysql /'
        for db in $(local_psql "$q_pg_db"); do echo "postgres $db $(local_psql "$q_pg_tbl" "$db")"; done)"
    new_sum="$(rrun 'docker compose exec -T -e MYSQL_PWD="$MYSQL_ROOT_PASSWORD" mysql mysql -uroot -N -B -e "$1" | sed "s/^/mysql /"
        p() { docker compose exec -T postgres psql -U "$POSTGRES_USER" -d "$1" -tAc "$2"; }
        for db in $(p "$POSTGRES_DB" "$2"); do echo "postgres $db $(p "$db" "$3")"; done' \
        "$q_mysql" "$q_pg_db" "$q_pg_tbl")"
    if [ "$old_sum" = "$new_sum" ]; then
        echo "$new_sum" | awk '{printf "   ✅ %-9s %-30s %s tabel\n", $1, $2, $3}'
    else
        echo "   ⚠️  Ada perbedaan (lama vs baru):"
        diff <(echo "$old_sum") <(echo "$new_sum") | sed 's/^/      /' || true
    fi

    echo ""
    echo "✅ Migrasi selesai. Server baru ($TARGET) sudah berjalan dengan data dari server ini."
    echo "   Data yang ditulis ke server lama SETELAH langkah 4-5 tidak ikut pindah."
    echo "   Arahkan aplikasi ke server baru, server lama tetap berjalan sebagai cadangan."
}

case "${1:-}" in
    export) shift; do_export "$@" ;;
    import) shift; do_import "$@" ;;
    push) shift; do_push "$@" ;;
    *) usage ;;
esac
