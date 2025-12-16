#!/bin/bash

# Script untuk menjalankan database production
# Usage: ./start-production-db.sh

set -e

echo "🚀 Starting Production Databases..."

# Pastikan file environment ada
if [ ! -f ".env" ]; then
    echo "❌ File .env tidak ditemukan!"
    if [ -f ".env.example" ]; then
        echo "📝 File .env.example ditemukan. Copy ke .env dan sesuaikan konfigurasi:"
        echo "   cp .env.example .env"
        echo "   nano .env"
    else
        echo "Silakan buat file .env dengan konfigurasi database"
    fi
    exit 1
fi

# Buat direktori yang diperlukan
mkdir -p mysql/conf.d
mkdir -p postgres/init

# Start containers
echo "📦 Starting Docker containers..."
docker compose up -d

# Wait for databases to be ready
echo "⏳ Menunggu database siap..."
sleep 10

# Check MySQL
echo "🔍 Checking MySQL connection..."
source .env
docker exec shared-prod-mysql mysqladmin ping -h localhost -u root -p${MYSQL_ROOT_PASSWORD} || echo "❌ MySQL belum siap"

# Check PostgreSQL
echo "🔍 Checking PostgreSQL connection..."
docker exec shared-prod-postgres pg_isready -U ${POSTGRES_USER} -d ${POSTGRES_DB} || echo "❌ PostgreSQL belum siap"

echo "✅ Database production sudah berjalan!"
echo ""
echo "📊 Koneksi Database:"
echo "MySQL:"
echo "  Host: localhost"
echo "  Port: 9540"
echo "  Database: ${MYSQL_DATABASE}"
echo "  User: ${MYSQL_USER}"
echo "  Password: (lihat di .env)"
echo ""
echo "PostgreSQL:"
echo "  Host: localhost"
echo "  Port: 9541"
echo "  Database: ${POSTGRES_DB}"
echo "  User: ${POSTGRES_USER}"
echo "  Password: (lihat di .env)"
echo ""
echo "🌐 Adminer (Web DB Manager):"
echo "  URL: http://localhost:9542"
echo ""
echo "📝 Untuk melihat logs: docker compose logs -f"
echo "🛑 Untuk stop: docker compose down"
