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
    sed -n '3,22p' "$0" | sed 's/^# \{0,1\}//'
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
    grep -E "^$1=" .env | tail -1 | cut -d= -f2- | tr -d '"'"'"'\r'
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

case "${1:-}" in
    export) shift; do_export "$@" ;;
    import) shift; do_import "$@" ;;
    *) usage ;;
esac
