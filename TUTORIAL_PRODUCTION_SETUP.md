# 🚀 Tutorial Setup Database Production

Tutorial lengkap untuk setup database production dengan MySQL dan PostgreSQL menggunakan Docker.

## 📋 Prerequisites

- Docker dan Docker Compose sudah terinstall
- Port 9540, 9541, dan 9542 tersedia di sistem
- Minimal 2GB RAM tersedia untuk Docker

## 🔧 Setup Production Database

### 1. Persiapan File

Pastikan file-file berikut ada di direktori project:
- `docker-compose.production.yml`
- `production.env`
- `start-production-db.sh`
- `stop-production-db.sh`

### 2. Konfigurasi Environment

Edit file `production.env` sesuai kebutuhan:

```bash
# Database Configuration for Production
# Ganti password ini dengan password yang lebih aman untuk production

# MySQL Configuration
MYSQL_ROOT_PASSWORD=Rubysa179596!
MYSQL_DATABASE=shared_db
MYSQL_USER=msiserver
MYSQL_PASSWORD=Rubysa179596!

# PostgreSQL Configuration
POSTGRES_USER=msiserver
POSTGRES_PASSWORD=Rubysa179596!
POSTGRES_DB=shared_pgdb

# Network Configuration
COMPOSE_PROJECT_NAME=shared_prod_db
```

### 3. Mulai Production Database

```bash
# Jalankan script start
./start-production-db.sh
```

### 4. Verifikasi Setup

Setelah script selesai, verifikasi bahwa semua container berjalan:

```bash
# Cek status container
docker ps --filter "name=shared-prod"

# Test koneksi MySQL
docker exec shared-prod-mysql mysqladmin ping -h localhost -u root -pRubysa179596!

# Test koneksi PostgreSQL
docker exec shared-prod-postgres pg_isready -U msiserver -d shared_pgdb
```

## 📊 Informasi Koneksi Production

### MySQL
- **Host**: localhost
- **Port**: 9540
- **Database**: shared_db
- **User**: msiserver
- **Password**: (lihat di production.env)

### PostgreSQL
- **Host**: localhost
- **Port**: 9541
- **Database**: shared_pgdb
- **User**: msiserver
- **Password**: (lihat di production.env)

### Adminer (Web Database Manager)
- **URL**: http://localhost:9542
- **Server**: shared-prod-mysql atau shared-prod-postgres
- **Username**: msiserver
- **Password**: (lihat di production.env)

## 🛠️ Perintah Berguna

### Melihat Logs
```bash
# Semua services
docker-compose -f docker-compose.production.yml logs -f

# MySQL saja
docker-compose -f docker-compose.production.yml logs -f mysql

# PostgreSQL saja
docker-compose -f docker-compose.production.yml logs -f postgres
```

### Menghentikan Database
```bash
# Stop containers (data tetap tersimpan)
./stop-production-db.sh

# Atau manual
docker-compose -f docker-compose.production.yml down
```

### Backup Database
```bash
# Backup MySQL
docker exec shared-prod-mysql mysqldump -u root -pRubysa179596! shared_db > mysql_backup.sql

# Backup PostgreSQL
docker exec shared-prod-postgres pg_dump -U msiserver shared_pgdb > postgres_backup.sql
```

### Restore Database
```bash
# Restore MySQL
docker exec -i shared-prod-mysql mysql -u root -pRubysa179596! shared_db < mysql_backup.sql

# Restore PostgreSQL
docker exec -i shared-prod-postgres psql -U msiserver -d shared_pgdb < postgres_backup.sql
```

## 🔒 Keamanan Production

### 1. Ganti Password Default
Pastikan untuk mengganti password default di `production.env` dengan password yang kuat.

### 2. Firewall
Konfigurasi firewall untuk membatasi akses ke port database.

### 3. SSL/TLS
Untuk production, pertimbangkan untuk menggunakan SSL/TLS untuk koneksi database.

### 4. Regular Backup
Setup backup otomatis untuk data production.

## 🚨 Troubleshooting

### Port Already in Use
Jika port sudah digunakan, edit `docker-compose.production.yml` dan ganti port mapping:
```yaml
ports:
  - "9543:3306"  # MySQL
  - "9544:5432"  # PostgreSQL
  - "9545:8080"  # Adminer
```

### Network Conflict
Jika ada konflik network, edit subnet di `docker-compose.production.yml`:
```yaml
networks:
  prod_network:
    driver: bridge
    ipam:
      config:
        - subnet: 172.35.0.0/16  # Ganti subnet
```

### Container Won't Start
```bash
# Cek logs untuk error
docker-compose -f docker-compose.production.yml logs

# Hapus container dan volume (HATI-HATI: Data akan hilang!)
docker-compose -f docker-compose.production.yml down -v
```

## 📈 Monitoring

### Resource Usage
```bash
# Monitor resource usage
docker stats shared-prod-mysql shared-prod-postgres

# Monitor disk usage
docker system df
```

### Health Check
```bash
# Cek health status
docker inspect shared-prod-mysql --format='{{.State.Health.Status}}'
docker inspect shared-prod-postgres --format='{{.State.Health.Status}}'
```

## 🔄 Maintenance

### Update Images
```bash
# Pull latest images
docker-compose -f docker-compose.production.yml pull

# Restart dengan image baru
docker-compose -f docker-compose.production.yml up -d
```

### Clean Up
```bash
# Hapus unused images
docker image prune

# Hapus unused volumes (HATI-HATI!)
docker volume prune
```

## 📞 Support

Jika mengalami masalah:
1. Cek logs dengan perintah di atas
2. Verifikasi konfigurasi environment
3. Pastikan port tidak conflict
4. Cek resource availability (RAM, disk space)

