#!/bin/bash

# Script untuk menjalankan database production
# Usage: ./start-production-db.sh

set -e

echo "🚀 Starting Production Databases..."

# Pastikan file environment ada
if [ ! -f "production.env" ]; then
    echo "❌ File production.env tidak ditemukan!"
    echo "Silakan copy dari production.env.example dan sesuaikan konfigurasi"
    exit 1
fi

# Buat direktori yang diperlukan
mkdir -p mysql/conf.d
mkdir -p postgres/init

# Start containers
echo "📦 Starting Docker containers..."
docker-compose --env-file production.env -f docker-compose.production.yml up -d

# Wait for databases to be ready
echo "⏳ Menunggu database siap..."
sleep 10

# Check MySQL
echo "🔍 Checking MySQL connection..."
source production.env
docker exec shared-prod-mysql mysqladmin ping -h localhost -u root -p${MYSQL_ROOT_PASSWORD} || echo "❌ MySQL belum siap"

# Check PostgreSQL
echo "🔍 Checking PostgreSQL connection..."
docker exec shared-prod-postgres pg_isready -U msiserver -d shared_pgdb || echo "❌ PostgreSQL belum siap"

echo "✅ Database production sudah berjalan!"
echo ""
echo "📊 Koneksi Database:"
echo "MySQL:"
echo "  Host: localhost"
echo "  Port: 9540"
echo "  Database: shared_db"
echo "  User: msiserver"
echo "  Password: (lihat di production.env)"
echo ""
echo "PostgreSQL:"
echo "  Host: localhost"
echo "  Port: 9541"
echo "  Database: shared_pgdb"
echo "  User: msiserver"
echo "  Password: (lihat di production.env)"
echo ""
echo "🌐 Adminer (Web DB Manager):"
echo "  URL: http://localhost:9542"
echo ""
echo "📝 Untuk melihat logs: docker-compose -f docker-compose.production.yml logs -f"
echo "🛑 Untuk stop: docker-compose -f docker-compose.production.yml down"
