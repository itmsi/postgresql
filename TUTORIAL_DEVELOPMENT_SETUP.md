# 🛠️ Tutorial Setup Database Development

Tutorial lengkap untuk setup database development dengan MySQL dan PostgreSQL menggunakan Docker.

## 📋 Prerequisites

- Docker dan Docker Compose sudah terinstall
- Port 3307, 5433, dan 8081 tersedia di sistem
- Minimal 1GB RAM tersedia untuk Docker

## 🔧 Setup Development Database

### 1. Persiapan File

Pastikan file-file berikut ada di direktori project:
- `docker-compose.development.yml`
- `development.env`
- `start-development-db.sh`
- `stop-development-db.sh`

### 2. Konfigurasi Environment

Edit file `development.env` sesuai kebutuhan development:

```bash
# Database Configuration for Development
# Password ini aman untuk development, tapi pastikan untuk menggunakan password yang berbeda di production

# MySQL Configuration
MYSQL_ROOT_PASSWORD=DevPassword123!
MYSQL_DATABASE=shared_dev_db
MYSQL_USER=devuser
MYSQL_PASSWORD=DevPassword123!

# PostgreSQL Configuration
POSTGRES_USER=devuser
POSTGRES_PASSWORD=DevPassword123!
POSTGRES_DB=shared_dev_pgdb

# Network Configuration
COMPOSE_PROJECT_NAME=shared_dev_db
```

### 3. Mulai Development Database

```bash
# Jalankan script start
./start-development-db.sh
```

### 4. Verifikasi Setup

Setelah script selesai, verifikasi bahwa semua container berjalan:

```bash
# Cek status container
docker ps --filter "name=shared-dev"

# Test koneksi MySQL
docker exec shared-dev-mysql mysqladmin ping -h localhost -u root -pDevPassword123!

# Test koneksi PostgreSQL
docker exec shared-dev-postgres pg_isready -U devuser -d shared_dev_pgdb
```

## 📊 Informasi Koneksi Development

### MySQL
- **Host**: localhost
- **Port**: 3307
- **Database**: shared_dev_db
- **User**: devuser
- **Password**: DevPassword123!

### PostgreSQL
- **Host**: localhost
- **Port**: 5433
- **Database**: shared_dev_pgdb
- **User**: devuser
- **Password**: DevPassword123!

### Adminer (Web Database Manager)
- **URL**: http://localhost:8081
- **Server**: shared-dev-mysql atau shared-dev-postgres
- **Username**: devuser
- **Password**: DevPassword123!

## 🛠️ Perintah Berguna untuk Development

### Melihat Logs
```bash
# Semua services
docker-compose -f docker-compose.development.yml logs -f

# MySQL saja
docker-compose -f docker-compose.development.yml logs -f mysql

# PostgreSQL saja
docker-compose -f docker-compose.development.yml logs -f postgres
```

### Menghentikan Database
```bash
# Stop containers (data tetap tersimpan)
./stop-development-db.sh

# Atau manual
docker-compose -f docker-compose.development.yml down
```

### Reset Development Data
```bash
# Hapus semua data development (HATI-HATI!)
docker-compose -f docker-compose.development.yml down -v

# Mulai ulang
./start-development-db.sh
```

### Import Sample Data
```bash
# Import data ke MySQL
docker exec -i shared-dev-mysql mysql -u devuser -pDevPassword123! shared_dev_db < sample_data.sql

# Import data ke PostgreSQL
docker exec -i shared-dev-postgres psql -U devuser -d shared_dev_pgdb < sample_data.sql
```

## 🔄 Development Workflow

### 1. Mulai Development Session
```bash
# Start development database
./start-development-db.sh

# Mulai coding dengan database yang sudah siap
```

### 2. Reset Data Saat Perlu
```bash
# Jika perlu data bersih
docker-compose -f docker-compose.development.yml down -v
./start-development-db.sh
```

### 3. Akhiri Development Session
```bash
# Stop development database
./stop-development-db.sh
```

## 🧪 Testing dengan Development Database

### Unit Testing
```bash
# Contoh test dengan MySQL
mysql -h localhost -P 3307 -u devuser -pDevPassword123! shared_dev_db -e "SELECT 1;"

# Contoh test dengan PostgreSQL
psql -h localhost -p 5433 -U devuser -d shared_dev_pgdb -c "SELECT 1;"
```

### Integration Testing
```bash
# Test aplikasi dengan database development
export DB_HOST=localhost
export DB_PORT=3307  # atau 5433 untuk PostgreSQL
export DB_USER=devuser
export DB_PASSWORD=DevPassword123!
export DB_NAME=shared_dev_db  # atau shared_dev_pgdb untuk PostgreSQL
```

## 🔧 Customization Development

### Tambah Environment Variables
Edit `development.env` untuk menambah konfigurasi:
```bash
# Tambahan konfigurasi
DEBUG=true
LOG_LEVEL=debug
API_PORT=3000
```

### Custom MySQL Configuration
Buat file `mysql/conf.d/my.cnf`:
```ini
[mysqld]
character-set-server=utf8mb4
collation-server=utf8mb4_unicode_ci
max_connections=100
```

### Custom PostgreSQL Configuration
Buat file `postgres/init/init.sql`:
```sql
-- Custom initialization script
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
```

## 🚨 Troubleshooting Development

### Port Conflict
Jika port sudah digunakan, edit `docker-compose.development.yml`:
```yaml
ports:
  - "3308:3306"  # MySQL
  - "5434:5432"  # PostgreSQL
  - "8082:8080"  # Adminer
```

### Container Won't Start
```bash
# Cek logs
docker-compose -f docker-compose.development.yml logs

# Restart dengan force
docker-compose -f docker-compose.development.yml down
docker-compose -f docker-compose.development.yml up -d
```

### Data Corruption
```bash
# Reset semua data development
docker-compose -f docker-compose.development.yml down -v
docker volume prune
./start-development-db.sh
```

## 🔄 Switching Between Environments

### Dari Development ke Production
```bash
# Stop development
./stop-development-db.sh

# Start production
./start-production-db.sh
```

### Dari Production ke Development
```bash
# Stop production
./stop-production-db.sh

# Start development
./start-development-db.sh
```

### Running Both Simultaneously
```bash
# Kedua environment bisa berjalan bersamaan karena menggunakan port dan network yang berbeda
./start-production-db.sh  # Port: 9540, 9541, 9542
./start-development-db.sh # Port: 3307, 5433, 8081
```

## 📈 Development Monitoring

### Resource Usage
```bash
# Monitor development containers
docker stats shared-dev-mysql shared-dev-postgres

# Monitor semua containers
docker stats
```

### Database Performance
```bash
# MySQL process list
docker exec shared-dev-mysql mysql -u devuser -pDevPassword123! -e "SHOW PROCESSLIST;"

# PostgreSQL active connections
docker exec shared-dev-postgres psql -U devuser -d shared_dev_pgdb -c "SELECT * FROM pg_stat_activity;"
```

## 🧹 Cleanup Development

### Hapus Development Containers
```bash
# Hapus containers dan volumes
docker-compose -f docker-compose.development.yml down -v

# Hapus unused images
docker image prune
```

### Reset Development Environment
```bash
# Reset lengkap
docker-compose -f docker-compose.development.yml down -v
docker system prune -f
./start-development-db.sh
```

## 💡 Tips Development

1. **Gunakan port yang berbeda** untuk menghindari konflik dengan production
2. **Password sederhana** untuk development (tapi tetap aman)
3. **Reset data secara berkala** untuk testing yang konsisten
4. **Monitor resource usage** untuk menghindari masalah performa
5. **Gunakan volume mounting** untuk custom configuration

## 📞 Support

Jika mengalami masalah:
1. Cek logs dengan perintah di atas
2. Verifikasi port tidak conflict dengan production
3. Pastikan Docker memiliki resource cukup
4. Reset environment jika perlu

