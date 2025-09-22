# Setup Database Production dengan Docker

Setup ini menyediakan MySQL 8.0 dan PostgreSQL 15 untuk environment production yang bisa diakses dari luar menggunakan DBeaver atau tools database lainnya.

## 📋 Persyaratan

- Docker dan Docker Compose terinstall
- Port 9540 (MySQL), 9541 (PostgreSQL), dan 9542 (Adminer) tersedia

## 🚀 Cara Menjalankan

### 1. Konfigurasi Environment

Sesuaikan file `production.env` dengan kredensial yang aman:

```bash
# MySQL Configuration
MYSQL_ROOT_PASSWORD=password_aman_anda
MYSQL_DATABASE=shared_db
MYSQL_USER=msiserver
MYSQL_PASSWORD=password_aman_anda

# PostgreSQL Configuration
POSTGRES_USER=msiserver
POSTGRES_PASSWORD=password_aman_anda
POSTGRES_DB=shared_pgdb
```

### 2. Jalankan Database

```bash
./start-production-db.sh
```

### 3. Hentikan Database

```bash
./stop-production-db.sh
```

## 🔌 Koneksi Database

### MySQL
- **Host**: localhost (atau IP server)
- **Port**: 9540
- **Database**: shared_db
- **Username**: msiserver
- **Password**: (sesuai production.env)

### PostgreSQL
- **Host**: localhost (atau IP server)
- **Port**: 9541
- **Database**: shared_pgdb
- **Username**: msiserver
- **Password**: (sesuai production.env)

## 🛠️ Tools Database

### DBeaver
1. Buat koneksi baru
2. Pilih MySQL atau PostgreSQL
3. Masukkan host, port, dan kredensial sesuai di atas

### Adminer (Web-based)
- URL: http://localhost:9542
- Login dengan kredensial MySQL atau PostgreSQL

## 📁 Struktur File

```
.
├── docker-compose.production.yml    # Konfigurasi Docker Compose
├── production.env                   # Environment variables
├── start-production-db.sh          # Script start database
├── stop-production-db.sh           # Script stop database
├── mysql/
│   └── conf.d/
│       └── mysql.cnf               # Konfigurasi MySQL
└── postgres/
    └── init/
        └── 01-init.sql             # Script inisialisasi PostgreSQL
```

## 🔒 Keamanan

1. **Ganti Password Default**: Pastikan mengganti password di `production.env`
2. **Firewall**: Pastikan port hanya bisa diakses dari IP yang diperlukan
3. **Backup**: Setup backup rutin untuk data production

## 📊 Monitoring

### Melihat Status Container
```bash
docker ps
```

### Melihat Logs
```bash
# Semua logs
docker-compose -f docker-compose.production.yml logs -f

# MySQL saja
docker logs shared-prod-mysql -f

# PostgreSQL saja
docker logs shared-prod-postgres -f
```

### Health Check
```bash
# MySQL
docker exec shared-prod-mysql mysqladmin ping -h localhost

# PostgreSQL
docker exec shared-prod-postgres pg_isready -U msiserver
```

## 🗄️ Backup & Restore

### MySQL Backup
```bash
docker exec shared-prod-mysql mysqldump -u root -p shared_db > backup_mysql_$(date +%Y%m%d).sql
```

### PostgreSQL Backup
```bash
docker exec shared-prod-postgres pg_dump -U msiserver shared_pgdb > backup_postgres_$(date +%Y%m%d).sql
```

## ❌ Troubleshooting

### Port Sudah Digunakan
```bash
# Cek port yang digunakan
netstat -tulpn | grep :9540
netstat -tulpn | grep :9541
```

### Container Tidak Bisa Start
```bash
# Lihat logs error
docker-compose -f docker-compose.production.yml logs
```

### Reset Database
```bash
# Hentikan dan hapus data
docker-compose -f docker-compose.production.yml down -v

# Start ulang
./start-production-db.sh
```

## 🔧 Kustomisasi

- **MySQL Config**: Edit `mysql/conf.d/mysql.cnf`
- **PostgreSQL Init**: Tambah script di `postgres/init/`
- **Port**: Ubah di `docker-compose.production.yml`
