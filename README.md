# 🗄️ Shared Database Production (MySQL + PostgreSQL)

Database production berbasis Docker:

| Service    | Container              | Port host | Image            |
|------------|------------------------|-----------|------------------|
| MySQL      | `shared-prod-mysql`    | 9540      | `mysql:8.0`      |
| PostgreSQL | `shared-prod-postgres` | 9541      | `postgres:15`    |
| Adminer    | `shared-prod-adminer`  | 9542      | `adminer:latest` |

Konfigurasi ada di `.env` (lihat `.env.example`), service ada di `docker-compose.yml`.

- Start: `./start-production-db.sh`
- Stop: `./stop-production-db.sh`
- Tutorial setup: [TUTORIAL_PRODUCTION_SETUP.md](TUTORIAL_PRODUCTION_SETUP.md)

---

## ⚡ Migrasi Satu Command via Tailscale/SSH (direkomendasikan)

Cukup **satu command di server lama**. Command ini mengirim image, menarik semua data
langsung ke server baru, menyiapkan server baru, menjalankan container, dan memverifikasi hasilnya.

- ✅ **Tidak ada file yang ditulis di disk server lama**: image di-stream lewat SSH, data
  ditarik server baru langsung dari database yang sedang berjalan
- ✅ **Tanpa downtime**: database lama tetap melayani aplikasi selama proses
- ✅ **Tidak perlu menjalankan apa pun di server baru**
- ✅ Perubahan sementara di server lama (izin replikasi PostgreSQL & plugin clone MySQL)
  otomatis dicabut lagi di akhir, termasuk kalau migrasi gagal

### 🔑 Data yang dibutuhkan & disimpan di mana

| Informasi | Disimpan / dipakai di mana |
|-----------|----------------------------|
| **IP Tailscale & username server baru** | Langsung ditulis di command: `./migrate.sh push USERNAME@IP_TAILSCALE`. Bisa juga dibuat alias di `~/.ssh/config` (lihat langkah B3) |
| **Password SSH server baru** | **Tidak disimpan di mana pun.** Script memakai SSH key. Password hanya diketik **sekali** saat `ssh-copy-id` |
| **Username/password database** | Diambil otomatis dari `.env` di server lama |
| **IP Tailscale server lama** | Dideteksi otomatis (`tailscale ip -4`) |

### A. Setup di server baru

```bash
# 1. Docker & Docker Compose terpasang
docker compose version

# 2. Catat IP Tailscale server baru (dipakai di langkah B)
tailscale ip -4          # contoh: 100.101.102.103

# 3. SSH server aktif
sudo systemctl status ssh

# 4. Kalau login SSH-nya bukan root, user itu harus bisa menjalankan docker
sudo usermod -aG docker NAMA_USER     # lalu logout & login lagi

# 5. Ruang disk cukup (minimal ukuran data server lama + 2 GB)
df -h /var/lib/docker

# 6. Port 9540–9542 belum dipakai (harus kosong)
ss -ltnp | grep 954
```

Folder project di server baru **tidak wajib ada**, karena script akan mengirimnya sendiri.
Kalau sudah ada, isi `MYSQL_*`, `POSTGRES_*`, dan `COMPOSE_PROJECT_NAME` di `.env` harus sama
dengan server lama. Ini dicek otomatis.

### B. Setup di server lama

```bash
# 1. Buat SSH key (kalau belum punya; tekan Enter terus)
ssh-keygen -t ed25519

# 2. Kirim key ke server baru. Di sini password server baru diketik SEKALI
ssh-copy-id NAMA_USER@100.101.102.103

# 3. (Opsional) Alias supaya tidak perlu mengetik IP terus
cat >> ~/.ssh/config <<'EOF'
Host server-baru
    HostName 100.101.102.103
    User NAMA_USER
EOF

# 4. Tes: harus langsung tampil TANPA diminta password
ssh server-baru 'docker ps'

# 5. Pastikan IP Tailscale server lama terdeteksi
tailscale ip -4

# 6. Cek ukuran data, lalu bandingkan dengan sisa disk server baru (langkah A5)
sudo du -sh /var/lib/docker/volumes/shared_prod_db_*
```

### C. Jalankan migrasi (di server lama)

```bash
cd /path/ke/postgresql
tmux new -s migrasi        # supaya proses tetap jalan kalau koneksi terminal putus
                           # (kalau terputus, masuk lagi dengan: tmux attach -t migrasi)

# 1. Cek dulu semua syarat (tidak memigrasi data)
./migrate.sh push server-baru --check        # atau: NAMA_USER@100.101.102.103

# 2. Jalankan migrasi
./migrate.sh push server-baru --force
```

Kalau `--check` sudah lolos semua ✅, berarti semua setup di atas sudah benar.

> ⚠️ **`--force` menghapus total data MySQL & PostgreSQL yang sudah ada di server baru**, lalu
> menggantinya dengan data server lama (tidak digabung). Server lama tidak ikut diubah.
> Tanpa `--force`, script menolak jalan kalau di server baru sudah ada volume database.

Opsi:

| Opsi | Fungsi |
|------|--------|
| `--remote-dir DIR` | Folder project di server baru. Default: path yang sama dengan server lama |
| `--source-ip IP` | IP Tailscale server lama. Default: dideteksi otomatis dari `tailscale ip -4` |
| `--check` | Hanya pengecekan, tidak memigrasi |
| `--force` | Timpa volume yang sudah ada di server baru. **Wajib** kalau di server baru sudah pernah `docker compose up` |

Contoh kalau di server baru database sudah pernah dijalankan dan foldernya berbeda:

```bash
./migrate.sh push root@100.101.102.103 --remote-dir /root/postgresql --force
```

### Yang dikerjakan script

| Tahap | Proses |
|-------|--------|
| 1/7 | Cek SSH, Docker, `.env`, akses port, volume yang sudah ada, tabel non-InnoDB |
| 2/7 | Kirim image yang berbeda atau belum ada (`docker save \| ssh docker load`), jadi versi MySQL dijamin sama persis |
| 3/7 | Di server baru: `docker compose down`, hapus volume lama, buat network `infra_net` |
| 4/7 | PostgreSQL: izin replikasi sementara di server lama, lalu `pg_basebackup` dari server baru |
| 5/7 | MySQL: plugin clone dipasang sementara, lalu server baru menarik data dengan `CLONE INSTANCE` |
| 6/7 | `docker compose up -d` di server baru dan tunggu sampai siap |
| 7/7 | Bandingkan daftar database & jumlah tabel di server lama dan server baru |

Contoh output di akhir:

```
🔍 [7/7] Verifikasi (daftar database & jumlah tabel)
   ✅ mysql     shared_db                      12 tabel
   ✅ postgres  shared_pgdb                    34 tabel
✅ Migrasi selesai. Server baru (root@100.101.102.103) sudah berjalan dengan data dari server ini.
```

### ❗ Hal yang sering bikin gagal

| Masalah | Solusi |
|---------|--------|
| `❌ SSH ke ... gagal` padahal `ssh` manual bisa | Jalankan script dengan **user yang sama** dengan yang dipakai di langkah B. Kalau pakai `sudo ./migrate.sh`, yang dipakai adalah SSH key milik root. Kalau memang harus root, lakukan langkah B sebagai root juga |
| `ssh-copy-id` gagal karena server baru menolak login dengan password | Tambahkan isi `~/.ssh/id_ed25519.pub` dari server lama secara manual ke `~/.ssh/authorized_keys` di server baru |
| Folder project di server baru berbeda | Default-nya sama dengan path di server lama. Kalau berbeda, tambahkan `--remote-dir /root/postgresql` |
| `IP server lama tidak terdeteksi` | Command `tailscale` tidak ada di server lama (misalnya karena Tailscale jalan di container). Isi manual dengan `--source-ip 100.x.x.x` |
| `Server baru tidak bisa akses ...:9540` | Cek Tailscale (`tailscale status`) dan firewall server lama untuk port 9540/9541 |
| `Isi ... .env server baru berbeda` | Samakan `.env` server baru dengan server lama, atau hapus folder project di server baru supaya dikirim ulang oleh script |
| `Docker ... belum terpasang, atau user SSH tidak punya akses docker` | Pasang Docker, atau jalankan `sudo usermod -aG docker NAMA_USER` di server baru |
| Memakai **Tailscale SSH** | Langkah B1–B2 tidak perlu, asalkan ACL Tailscale tidak meminta konfirmasi login lewat browser (mode `check`) |

### 🛡️ Kalau migrasi gagal di tengah jalan

- **Server lama aman.** Proses ini hanya membaca data dari server lama. Database dan aplikasi
  tetap jalan. Izin replikasi dan plugin clone yang dipasang sementara otomatis dicabut walaupun gagal.
- **Server baru** mungkin berisi data setengah jadi. Perbaiki penyebabnya, lalu jalankan ulang
  `./migrate.sh push server-baru --force`. Semuanya ditarik ulang dari awal.
- Kalau proses **dihentikan paksa** (`kill -9`, server mati), pembersihan otomatis tidak sempat
  jalan. Bersihkan manual di server lama:
  ```bash
  cd /path/ke/postgresql && source .env
  docker exec shared-prod-postgres bash -c 'sed -i "/# migrate.sh push$/d" "$PGDATA/pg_hba.conf"'
  docker exec shared-prod-postgres psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "SELECT pg_reload_conf();"
  docker exec -e MYSQL_PWD="$MYSQL_ROOT_PASSWORD" shared-prod-mysql mysql -uroot -e "UNINSTALL PLUGIN clone;"
  ```
- Kalau data yang sudah ada di server baru ingin dicadangkan dulu sebelum ditimpa, jalankan
  di server baru sebelum `push --force`:
  ```bash
  cd /path/ke/postgresql && docker compose down
  for v in mysql_prod_data postgres_prod_data; do
    docker run --rm -v shared_prod_db_$v:/data:ro -v "$PWD":/backup postgres:15 \
      tar --numeric-owner -czf /backup/backup-$v.tar.gz -C /data .
  done
  ```

### ✅ Urutan yang aman

1. Selesaikan setup A & B, lalu masuk `tmux new -s migrasi`
2. `./migrate.sh push server-baru --check` sampai semua ✅
3. Di jam sepi, hentikan aplikasi yang menulis ke database. Jangan ada migration/ALTER TABLE selama proses
4. `./migrate.sh push server-baru --force`
5. Pastikan hasil verifikasi semua ✅, lalu arahkan aplikasi ke IP server baru
6. Biarkan server lama tetap jalan beberapa hari sebagai cadangan

> ⏱️ Data yang ditulis ke server lama **setelah tahap 4 dan 5** tidak ikut pindah. Supaya
> tidak ada data yang tertinggal, hentikan dulu aplikasi yang menulis ke database, jalankan
> `push`, lalu nyalakan aplikasi dengan koneksi ke server baru. Kalau perlu mengulang,
> cukup jalankan lagi dengan `--force`.

---

## 🚚 Migrasi Manual ke Server Baru (disk server lama hampir penuh)

Ini cara manual, langkah demi langkah, dari command `push` di atas. Pakai cara ini kalau SSH dari server lama
ke server baru tidak memungkinkan.

Cara ini **tidak membuat file backup apa pun di server lama**. Server baru **menarik data
langsung lewat jaringan** dari database yang sedang berjalan, jadi:

- ✅ Tidak butuh ruang disk tambahan di server lama
- ✅ Tidak ada downtime, database lama tetap melayani aplikasi
- ✅ Tidak pakai dump DB. Yang disalin adalah data fisik, termasuk user, password, dan semua database

Sudah diuji: PostgreSQL via `pg_basebackup`, MySQL via `CLONE INSTANCE` (MySQL 8.0).

### 🗺️ Apa dipindah ke mana

| Apa | Di server lama | Cara pindah | Di server baru |
|-----|----------------|-------------|----------------|
| File konfigurasi | Folder project: `.env`, `docker-compose.yml`, `mysql/conf.d/`, `postgres/init/`, `*.sh`, `*.md` | **FTP/SFTP manual** (kecil, beberapa KB) | Folder project, misal `~/postgresql/` |
| Image Docker | `mysql:8.0`, `postgres:15`, `adminer:latest` | **Download ulang** di server baru (`docker compose pull`) | Docker image |
| Data PostgreSQL | Volume `shared_prod_db_postgres_prod_data` | **Ditarik server baru** dengan `pg_basebackup` (Langkah 3) | Volume `shared_prod_db_postgres_prod_data` |
| Data MySQL | Volume `shared_prod_db_mysql_prod_data` | **Ditarik server baru** dengan `CLONE INSTANCE` (Langkah 4) | Volume `shared_prod_db_mysql_prod_data` |

> Lokasi fisik volume di host: `/var/lib/docker/volumes/<nama_volume>/_data`.
> Volume **tidak perlu** di-FTP manual kalau memakai cara ini.

Di semua perintah di bawah, ganti:
- `OLD_IP` dengan IP server lama
- `NEW_IP` dengan IP server baru

---

### Langkah 0: Persiapan & pengecekan

**Di server lama**, jalankan dari folder project:

```bash
cd /path/ke/postgresql
source .env

# 1. Catat versi MySQL. Server baru WAJIB pakai versi yang sama persis
docker exec shared-prod-mysql mysqld --version
#    contoh output: Ver 8.0.46  -> catat "8.0.46"

# 2. Ukuran data (untuk memastikan disk server baru cukup)
sudo du -sh /var/lib/docker/volumes/shared_prod_db_*

# 3. Cek tabel MySQL non-InnoDB (isinya TIDAK ikut ter-clone)
docker exec -e MYSQL_PWD="$MYSQL_ROOT_PASSWORD" shared-prod-mysql mysql -uroot -e "
  SELECT table_schema, table_name, engine FROM information_schema.tables
  WHERE engine <> 'InnoDB'
    AND table_schema NOT IN ('mysql','sys','information_schema','performance_schema');"
#    Kalau ada hasil, ubah dulu: ALTER TABLE nama_db.nama_tabel ENGINE=InnoDB;
```

**Di server baru:**

```bash
# Docker & Docker Compose sudah terinstall
docker compose version

# Server baru harus bisa akses port 9540 (MySQL) & 9541 (PostgreSQL) server lama
nc -zv OLD_IP 9540
nc -zv OLD_IP 9541
```

Kalau `nc` gagal, buka firewall atau security group server lama untuk IP server baru di port 9540 dan 9541.

---

### Langkah 1: Pindahkan file konfigurasi (FTP/SFTP)

Dari folder project di server lama, upload ke folder yang sama di server baru (misal `~/postgresql/`):

```
.env                          <- WAJIB (password database ada di sini)
docker-compose.yml            <- WAJIB
mysql/conf.d/                 <- folder (walaupun kosong)
postgres/init/                <- folder (walaupun kosong)
start-production-db.sh
stop-production-db.sh
migrate.sh
README.md
```

> ⚠️ Pakai mode **Binary** di FTP. 🔒 Disarankan **SFTP**, karena `.env` berisi password.

---

### Langkah 2: Siapkan server baru

```bash
cd ~/postgresql
chmod +x *.sh
sed -i 's/\r$//' .env *.sh        # jaga-jaga kalau sempat lewat Windows
```

Edit `docker-compose.yml`, kunci versi MySQL sesuai hasil Langkah 0 (wajib untuk clone):

```yaml
  mysql:
    image: mysql:8.0.46     # sebelumnya: mysql:8.0
```

Lalu:

```bash
docker network create infra_net   # abaikan error kalau sudah ada
docker compose pull               # download image
```

---

### Langkah 3: Pindahkan data PostgreSQL

**Di server lama**, izinkan server baru melakukan replikasi. Perubahan ini hanya reload config, tanpa restart:

```bash
cd /path/ke/postgresql && source .env
docker exec shared-prod-postgres bash -c 'echo "host replication all NEW_IP/32 md5" >> "$PGDATA/pg_hba.conf"'
docker exec shared-prod-postgres psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "SELECT pg_reload_conf();"
```

**Di server baru**, tarik datanya langsung ke volume:

```bash
cd ~/postgresql && source .env
OLD_IP=xxx.xxx.xxx.xxx

docker volume create \
  --label com.docker.compose.project=shared_prod_db \
  --label com.docker.compose.volume=postgres_prod_data \
  shared_prod_db_postgres_prod_data

docker run --rm \
  -e PGPASSWORD="$POSTGRES_PASSWORD" \
  -v shared_prod_db_postgres_prod_data:/var/lib/postgresql/data \
  postgres:15 \
  bash -c "chown postgres:postgres /var/lib/postgresql/data && chmod 700 /var/lib/postgresql/data && \
           gosu postgres pg_basebackup -h $OLD_IP -p 9541 -U $POSTGRES_USER \
             -D /var/lib/postgresql/data -Fp -X stream -c fast -P"
```

Selesai kalau progress mencapai `100%`.
Kalau gagal di tengah jalan, hapus volume (`docker volume rm shared_prod_db_postgres_prod_data`) lalu ulangi.

---

### Langkah 4: Pindahkan data MySQL

**Di server lama**, pasang plugin clone (tanpa restart):

```bash
cd /path/ke/postgresql && source .env
docker exec -e MYSQL_PWD="$MYSQL_ROOT_PASSWORD" shared-prod-mysql mysql -uroot \
  -e "INSTALL PLUGIN clone SONAME 'mysql_clone.so';"
```

**Di server baru**, jalankan MySQL kosong, lalu clone dari server lama:

```bash
cd ~/postgresql && source .env
OLD_IP=xxx.xxx.xxx.xxx

docker compose up -d mysql

# tunggu sampai MySQL siap (ulangi sampai muncul "mysqld is alive")
docker exec -e MYSQL_PWD="$MYSQL_ROOT_PASSWORD" shared-prod-mysql mysqladmin -uroot ping

docker exec -e MYSQL_PWD="$MYSQL_ROOT_PASSWORD" shared-prod-mysql mysql -uroot -e "
  INSTALL PLUGIN clone SONAME 'mysql_clone.so';
  SET GLOBAL clone_valid_donor_list = '$OLD_IP:9540';
  CLONE INSTANCE FROM 'root'@'$OLD_IP':9540 IDENTIFIED BY '$MYSQL_ROOT_PASSWORD';"
```

Di akhir akan muncul error berikut. **Ini normal**, datanya sudah ter-clone:

```
ERROR 3707 (HY000): Restart server failed (mysqld is not managed by supervisor process).
```

Lalu restart MySQL:

```bash
docker compose restart mysql
```

> Clone menimpa seluruh isi MySQL di server baru, termasuk user dan password. Hasilnya sama persis dengan server lama.

---

### Langkah 5: Jalankan & verifikasi di server baru

```bash
cd ~/postgresql && source .env
docker compose up -d
docker compose ps

# MySQL
docker exec -e MYSQL_PWD="$MYSQL_PASSWORD" shared-prod-mysql mysql -u"$MYSQL_USER" -e "SHOW DATABASES;"

# PostgreSQL
docker exec shared-prod-postgres psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "\l"
```

Bandingkan jumlah baris beberapa tabel penting di server lama dan server baru:

```bash
docker exec shared-prod-postgres psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "SELECT count(*) FROM nama_tabel;"
docker exec -e MYSQL_PWD="$MYSQL_PASSWORD" shared-prod-mysql mysql -u"$MYSQL_USER" "$MYSQL_DATABASE" -e "SELECT count(*) FROM nama_tabel;"
```

---

### Langkah 6: Pindahkan aplikasi & bersihkan

1. Arahkan aplikasi ke `NEW_IP` (port tetap **9540** / **9541**).
2. **Server lama**: cabut izin replikasi dan plugin clone:
   ```bash
   cd /path/ke/postgresql && source .env
   docker exec shared-prod-postgres bash -c 'sed -i "/^host replication all NEW_IP\/32 md5$/d" "$PGDATA/pg_hba.conf"'
   docker exec shared-prod-postgres psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "SELECT pg_reload_conf();"
   docker exec -e MYSQL_PWD="$MYSQL_ROOT_PASSWORD" shared-prod-mysql mysql -uroot -e "UNINSTALL PLUGIN clone;"
   ```
3. **Server baru**: baris replikasi tadi ikut tersalin ke `pg_hba.conf`. Hapus dengan perintah `sed` + `pg_reload_conf()` yang sama, dijalankan di server baru.
4. Setelah server baru stabil beberapa hari, matikan database lama dengan `./stop-production-db.sh`.
   **Jangan hapus volume lama** sebelum yakin, karena itu cadangan Anda.

> ⏱️ **Data yang ditulis ke server lama setelah Langkah 3 dan 4 tidak ikut pindah.**
> Supaya tidak ada data yang tertinggal: hentikan dulu aplikasi yang menulis ke database,
> jalankan Langkah 3 dan 4, lalu nyalakan aplikasi dengan koneksi ke server baru.
> Downtime aplikasi hanya selama proses transfer data.
> Kalau perlu mengulang dari awal, hapus volume di server baru
> (`docker compose down -v`) lalu ulangi Langkah 3 dan 4.

---

### Alternatif: salin folder volume secara langsung (ada downtime)

Kalau port database server lama tidak bisa diakses dari server baru, salin folder volume
apa adanya. Database **harus dimatikan** selama salinan terakhir.

```bash
# Server baru: siapkan volume kosong
docker volume create --label com.docker.compose.project=shared_prod_db --label com.docker.compose.volume=mysql_prod_data shared_prod_db_mysql_prod_data
docker volume create --label com.docker.compose.project=shared_prod_db --label com.docker.compose.volume=postgres_prod_data shared_prod_db_postgres_prod_data

# Server lama (sebagai root). Salinan 1 saat database masih jalan, untuk memperpendek downtime
sudo rsync -aHAX --numeric-ids --info=progress2 \
  /var/lib/docker/volumes/shared_prod_db_postgres_prod_data/_data/ \
  root@NEW_IP:/var/lib/docker/volumes/shared_prod_db_postgres_prod_data/_data/
sudo rsync -aHAX --numeric-ids --info=progress2 \
  /var/lib/docker/volumes/shared_prod_db_mysql_prod_data/_data/ \
  root@NEW_IP:/var/lib/docker/volumes/shared_prod_db_mysql_prod_data/_data/

# Matikan database. Downtime dimulai dari sini
./stop-production-db.sh

# Salinan 2: jalankan KEDUA perintah rsync di atas sekali lagi, ditambah --delete
# (cepat, hanya menyalin selisihnya)
sudo rsync -aHAX --numeric-ids --delete --info=progress2 \
  /var/lib/docker/volumes/shared_prod_db_postgres_prod_data/_data/ \
  root@NEW_IP:/var/lib/docker/volumes/shared_prod_db_postgres_prod_data/_data/
sudo rsync -aHAX --numeric-ids --delete --info=progress2 \
  /var/lib/docker/volumes/shared_prod_db_mysql_prod_data/_data/ \
  root@NEW_IP:/var/lib/docker/volumes/shared_prod_db_mysql_prod_data/_data/
```

Kalau memakai **FTP/SFTP** (FileZilla) untuk menyalin folder `_data`, login sebagai `root`.
Setelah upload, perbaiki owner dan permission di server baru, karena FTP tidak membawa owner file:

```bash
sudo chown -R 999:999 /var/lib/docker/volumes/shared_prod_db_mysql_prod_data/_data
sudo chown -R 999:999 /var/lib/docker/volumes/shared_prod_db_postgres_prod_data/_data
sudo chmod 700 /var/lib/docker/volumes/shared_prod_db_postgres_prod_data/_data
```

Setelah itu lanjut ke Langkah 5. Dengan cara ini versi MySQL juga harus sama persis (Langkah 2).

---

## 📦 Migrasi Otomatis dengan `migrate.sh` (butuh ruang disk kosong)

Pakai cara ini kalau disk server lama masih cukup lega.
Script `migrate.sh` memindahkan **semua data volume, image Docker, dan konfigurasi**
ke server lain **tanpa dump DB**. Di server baru cukup import, database langsung jalan
dengan data, user, password, dan port yang sama.

Secara default export berjalan **online (tanpa downtime)**:

- **MySQL**: plugin `CLONE` MySQL 8.0 (dipasang otomatis, dicopot lagi setelah selesai)
- **PostgreSQL**: `pg_basebackup`

Database tetap bisa dibaca dan ditulis selama proses export.

### Isi file bundle (`migration-<tanggal>-<jam>.tar`)

| File               | Isi                                                                 |
|--------------------|---------------------------------------------------------------------|
| `images.tar`       | Image `mysql:8.0`, `postgres:15`, `adminer:latest` (server baru tidak perlu internet) |
| `volumes/*.tar.gz` | Data MySQL & PostgreSQL (owner dan permission tetap sama)           |
| `project.tar.gz`   | `.env`, `docker-compose.yml`, `mysql/`, `postgres/`, semua script    |
| `manifest.env`     | Info project, host asal, waktu, mode backup                         |
| `SHA256SUMS`       | Checksum, otomatis dicek saat import                                |

### ✅ Persiapan

**Server lama**
- Container database sedang berjalan (untuk mode online)
- Ruang disk kosong minimal **±2× ukuran data** + ±500 MB untuk image

**Server baru**
- Docker dan Docker Compose sudah terinstall
- Port 9540, 9541, 9542 belum dipakai aplikasi lain
- Ruang disk kosong minimal **±3× ukuran file bundle**

Cek ukuran data di server lama:

```bash
docker system df -v | grep shared_prod_db
```

---

### Langkah 1: Export di server lama

```bash
cd /path/ke/postgresql
./migrate.sh export
```

Hasilnya ada di folder `migration-backups/`, contoh:

```
migration-backups/migration-20261024-050651.tar
```

Opsi lain:

```bash
./migrate.sh export /path/folder/lain   # simpan bundle di folder lain
./migrate.sh export --offline           # stop container sebentar selama backup (lihat catatan)
```

Simpan checksum bundle untuk dicocokkan setelah transfer:

```bash
sha256sum migration-backups/migration-*.tar
```

---

### Langkah 2: Pindahkan file ke server baru (FTP / SFTP)

Cukup **2 file**:

1. `migrate.sh`
2. `migration-backups/migration-xxxx.tar`

Upload ke folder tujuan di server baru, misalnya `~/postgresql/`.

> ⚠️ **Wajib pakai mode Binary**, jangan ASCII atau Auto. Mode ASCII merusak file `.tar`.
> Di FileZilla: menu *Transfer → Transfer type → Binary*.
>
> 🔒 Bundle berisi `.env` (password database). Kalau bisa pakai **SFTP**
> (FileZilla: protokol SFTP, port 22, login SSH), karena FTP biasa tidak terenkripsi.

Alternatif dengan `scp`:

```bash
scp migrate.sh migration-backups/migration-xxxx.tar user@server-baru:~/postgresql/
```

---

### Langkah 3: Import di server baru

```bash
cd ~/postgresql
sha256sum migration-xxxx.tar      # harus sama dengan hasil di server lama
chmod +x migrate.sh               # izin eksekusi biasanya hilang lewat FTP
./migrate.sh import migration-xxxx.tar
```

Script akan otomatis:

1. Extract bundle dan verifikasi checksum
2. Load semua image (`docker load`)
3. Restore `.env`, `docker-compose.yml`, dan file konfigurasi
4. Membuat dan mengisi volume data MySQL & PostgreSQL
5. Membuat network `infra_net` (kalau belum ada)
6. Menjalankan container (`docker compose up -d`)

Opsi import:

| Opsi         | Fungsi                                                                 |
|--------------|------------------------------------------------------------------------|
| `--force`    | Timpa volume dan file project yang sudah ada di server baru            |
| `--no-start` | Import saja, container tidak langsung dijalankan                       |

---

### Langkah 4: Verifikasi di server baru

```bash
docker ps --filter name=shared-prod
source .env

# MySQL
docker exec -e MYSQL_PWD="$MYSQL_PASSWORD" shared-prod-mysql \
  mysql -u"$MYSQL_USER" -e "SHOW DATABASES;"

# PostgreSQL
docker exec shared-prod-postgres psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "\l"
```

Bandingkan jumlah data beberapa tabel penting dengan server lama, contoh:

```bash
docker exec shared-prod-postgres psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "SELECT count(*) FROM nama_tabel;"
```

Adminer bisa dibuka di `http://IP-SERVER-BARU:9542`.

---

### Langkah 5: Pindahkan aplikasi ke server baru

1. Ubah host database di aplikasi ke IP server baru (port tetap **9540** / **9541**)
2. Pastikan firewall server baru membuka port yang dibutuhkan
3. Setelah aplikasi berjalan normal di server baru, matikan database lama:

```bash
# di server lama
./stop-production-db.sh
```

> Jangan hapus volume di server lama (`docker compose down -v`) sampai server baru
> sudah dipastikan berjalan normal beberapa hari. Itu adalah cadangan Anda.

---

### 📝 Catatan Penting

**Data yang ditulis setelah export tidak ikut pindah.**
Bundle adalah potret data pada saat `export` dijalankan. Supaya tidak ada data yang tertinggal:

- Lakukan di jam sepi, lalu langsung arahkan aplikasi ke server baru setelah import, **atau**
- Hentikan aplikasi yang menulis ke database, jalankan export, transfer, import, lalu jalankan aplikasi di server baru.

**Tabel non-InnoDB (MySQL).**
Plugin clone hanya menyalin isi tabel InnoDB (engine default MySQL 8). Kalau ada tabel
MyISAM atau engine lain, script akan menampilkan peringatan berisi daftar tabelnya. Untuk tabel seperti itu,
ubah dulu engine-nya:

```sql
ALTER TABLE nama_tabel ENGINE=InnoDB;
```

atau gunakan `./migrate.sh export --offline`.

**Mode offline.**
`--offline` menghentikan semua container selama volume dibackup (beberapa detik sampai
menit, tergantung ukuran data), lalu menjalankannya kembali secara otomatis.

### 🛠️ Troubleshooting

| Masalah | Solusi |
|---------|--------|
| `❌ Checksum tidak cocok` | File rusak saat transfer. Ulangi upload dengan mode **Binary**. |
| `❌ Volume ... sudah ada di server ini` | Server baru sudah punya data. Tambahkan `--force` untuk menimpa (data lama di server baru akan hilang). |
| `$'\r': command not found` | `migrate.sh` terkena format Windows. Jalankan `sed -i 's/\r$//' migrate.sh`. |
| `Permission denied` saat menjalankan script | Jalankan `chmod +x migrate.sh` atau `bash migrate.sh ...` |
| Port sudah dipakai | Hentikan aplikasi yang memakai port 9540/9541/9542, atau ubah port di `docker-compose.yml`. |
| Disk penuh saat export | Kosongkan ruang disk, atau simpan bundle ke disk lain: `./migrate.sh export /mnt/disk-lain` |
