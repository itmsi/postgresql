#!/bin/bash

# Script untuk menjalankan database development
# Usage: ./start-development-db.sh

set -e

echo "🚀 Starting Development Databases..."

# Pastikan file environment ada
if [ ! -f "development.env" ]; then
    echo "❌ File development.env tidak ditemukan!"
    echo "Silakan copy dari development.env.example dan sesuaikan konfigurasi"
    exit 1
fi

# Buat direktori yang diperlukan
mkdir -p mysql/conf.d
mkdir -p postgres/init

# Start containers
echo "📦 Starting Docker containers..."
docker compose --env-file development.env -f docker-compose.development.yml up -d

# Wait for databases to be ready
echo "⏳ Menunggu database siap..."
sleep 10

# Load environment variables
source development.env

# Check MySQL
echo "🔍 Checking MySQL connection..."
docker exec shared-dev-mysql mysqladmin ping -h localhost -u root -p${MYSQL_ROOT_PASSWORD} || echo "❌ MySQL belum siap"

# Check PostgreSQL
echo "🔍 Checking PostgreSQL connection..."
docker exec shared-dev-postgres pg_isready -U devuser -d shared_dev_pgdb || echo "❌ PostgreSQL belum siap"

echo "✅ Database development sudah berjalan!"
echo ""
echo "📊 Koneksi Database Development:"
echo "MySQL:"
echo "  Host: localhost"
echo "  Port: 9552"
echo "  Database: shared_dev_db"
echo "  User: devuser"
echo "  Password: DevPassword123!"
echo ""
echo "PostgreSQL:"
echo "  Host: localhost"
echo "  Port: 9551"
echo "  Database: shared_dev_pgdb"
echo "  User: devuser"
echo "  Password: DevPassword123!"
echo ""
echo "🌐 Adminer (Web DB Manager):"
echo "  URL: http://localhost:8081"
echo ""
echo "📝 Untuk melihat logs: docker compose -f docker-compose.development.yml logs -f"
echo "🛑 Untuk stop: docker compose -f docker-compose.development.yml down"

