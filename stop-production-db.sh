#!/bin/bash

# Script untuk menghentikan database production
# Usage: ./stop-production-db.sh

echo "🛑 Stopping Production Databases..."

# Stop containers
echo "📦 Stopping Docker containers..."
docker compose down --remove-orphans

# Hapus container yang mungkin masih ada (jika ada konflik)
echo "🧹 Cleaning up any remaining containers..."
docker rm -f shared-prod-mysql shared-prod-postgres shared-prod-adminer 2>/dev/null || true

echo "✅ Database production sudah dihentikan!"
echo ""
echo "💡 Tips:"
echo "  - Data akan tetap tersimpan di Docker volumes"
echo "  - Untuk menghapus data juga, gunakan: docker compose down -v"
echo "  - Untuk melihat status: docker ps --filter 'name=shared-prod'"