#!/bin/bash

# Script untuk menghentikan database production
# Usage: ./stop-production-db.sh

echo "🛑 Stopping Production Databases..."

# Stop containers
echo "📦 Stopping Docker containers..."
docker-compose --env-file production.env -f docker-compose.production.yml down

echo "✅ Database production sudah dihentikan!"
echo ""
echo "💡 Tips:"
echo "  - Data akan tetap tersimpan di Docker volumes"
echo "  - Untuk menghapus data juga, gunakan: docker-compose -f docker-compose.production.yml down -v"
echo "  - Untuk melihat status: docker ps --filter 'name=shared-prod'"