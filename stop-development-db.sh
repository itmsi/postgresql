#!/bin/bash

# Script untuk menghentikan database development
# Usage: ./stop-development-db.sh

echo "🛑 Stopping Development Databases..."

# Stop containers
echo "📦 Stopping Docker containers..."
docker compose --env-file development.env -f docker-compose.development.yml down

echo "✅ Database development sudah dihentikan!"
echo ""
echo "💡 Tips:"
echo "  - Data akan tetap tersimpan di Docker volumes"
echo "  - Untuk menghapus data juga, gunakan: docker compose -f docker-compose.development.yml down -v"
echo "  - Untuk melihat status: docker ps --filter 'name=shared-dev'"

