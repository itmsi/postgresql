#!/bin/bash

# Script untuk menghentikan database production
# Usage: ./stop-production-db.sh

set -e

echo "🛑 Stopping Production Databases..."

# Stop containers
docker-compose --env-file production.env -f docker-compose.production.yml down

echo "✅ Database production sudah dihentikan!"
echo ""
echo "📝 Data tersimpan di Docker volumes:"
echo "  - mysql_prod_data (MySQL data)"
echo "  - postgres_prod_data (PostgreSQL data)"
echo ""
echo "🗑️  Untuk menghapus semua data: docker-compose -f docker-compose.production.yml down -v"
