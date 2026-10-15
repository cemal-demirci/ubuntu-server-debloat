# Ubuntu Server Debloat · Cemal.cloud

[![Lisans: MIT](https://img.shields.io/badge/lisans-MIT-blue)](LICENSE)
[![Denetim](https://github.com/cemal-demirci/ubuntu-server-debloat/actions/workflows/ci.yml/badge.svg)](https://github.com/cemal-demirci/ubuntu-server-debloat/actions)
![Ubuntu](https://img.shields.io/badge/Ubuntu%20Server-24.04%20LTS-E95420)

**Sunucunuzda sadece işini yapan paketler kalsın; snap, reklam ve telemetri değil.**

Ubuntu Server kurulur kurulmaz her SSH girişinde size Ubuntu Pro reklamı gösterir, arka planda snap güncellemelerini
kovalar, çöken süreçlerin raporlarını toplamaya hazır bekler. Modem yöneticisi, USB disk servisi gibi masaüstünden
kalma servisler de cabası. Hepsi RAM ve disk harcar, bir kısmı dışarıya bağlanır.

Silmek kolaydır; zor olan, `apt purge`'ün bağımlılık zinciriyle SSH'ı ya da netplan'ı da götürmediğinden emin
olmaktır. Bu yüzden bu script **her adımı önce simüle eder**:

- her paketi tek tek dener, korunan bir paketi de götürecekse onu listeden çıkarır,
- tüm planı bir kez daha dener; SSH, ağ ya da kernel gibi korunan bir paket etkileniyorsa **hiçbir şey yapmadan çıkar**,
- her çalıştırma için hazır bir `restore.sh` bırakır.

## Kurulum ve kullanım

```bash
curl -fsSLO https://raw.githubusercontent.com/cemal-demirci/ubuntu-server-debloat/main/ubuntu2404-debloat.sh
chmod +x ubuntu2404-debloat.sh

sudo ./ubuntu2404-debloat.sh --dry-run   # önce planı görün, hiçbir şey değişmez
sudo ./ubuntu2404-debloat.sh             # onaylayıp uygulayın
sudo reboot
```

Geri almak için çalıştırmanın bıraktığı scripti çağırın:

```bash
sudo /var/backups/cemalcloud-debloat/<tarih-saat>/restore.sh
```

## Elle mi, script ile mi?

| | `apt purge` ile elle | ubuntu-server-debloat |
|---|---|---|
| Bağımlılık zinciri | Siz kontrol edersiniz | ✅ Her paket önce simüle edilir |
| SSH, netplan, kernel | Yanlışlıkla gidebilir | ✅ Korunur, etkilenecekse script durur |
| snap'in geri gelmesi | Bir sonraki `apt install` ile geri gelebilir | ✅ apt pin ile engellenir |
| `jq`, `curl`, `git` gibi araçlar | `autoremove` ile gidebilir | ✅ Korunur |
| cloud-init | Bulutta da silinir | ✅ Yalnızca gerçek bir bulut ortamı yoksa silinir |
| Geri dönüş | Ne sildiğinizi hatırlamanız gerekir | ✅ Hazır `restore.sh` |

## Ne değişir?

| | |
|---|---|
| **Kaldırılır** | snap ve tüm snap paketleri (geri gelmesi de engellenir), apport, whoopsie ve popularity-contest (telemetri), landscape ve giriş mesajındaki reklamlar, pollinate, ModemManager, udisks2, plymouth, fwupd, lxd-installer, sosreport |
| **Kullanılmıyorsa kaldırılır** | cloud-init (gerçek bir bulut ortamı yoksa), multipath-tools (multipath disk yoksa), open-iscsi (aktif iSCSI bağlantısı yoksa) |
| **Ayarlanır** | Giriş mesajı ve apt reklamları susturulur, sistem günlüğü 500 MB ile sınırlanır, apt "önerilen" paketleri kendiliğinden kurmaz, needrestart her güncellemede soru sormaz |
| **Dokunulmaz** | SSH, sudo, netplan, systemd-resolved, kernel ve bootloader, LVM / RAID / LUKS araçları, otomatik güvenlik güncellemeleri, ubuntu-pro-client |

## Ne çalıştırır, nereye dokunur?

- **Çalıştırdığı:** yalnızca `apt`, `dpkg` ve snap'leri kaldırmak için `snap`. Paket kaldırmadan önce her plan
  `apt-get -s` ile simüle edilir. apt'nin cevabı okunamazsa (kilit, hata) script durur, tahmin yürütmez.
- **Yazdığı:** `/etc/apt/preferences.d/`, `/etc/apt/apt.conf.d/`, `/etc/systemd/journald.conf.d/` ve
  `/etc/needrestart/conf.d/` altına `cemalcloud` adlı birer dosya. `/etc/update-motd.d/` altındaki reklam
  scriptlerinin çalıştırma izni kapatılır. Yedekler ve `restore.sh` için `/var/backups/cemalcloud-debloat/`. Hepsini
  `restore.sh` geri alır.
- **Ağ:** script hiçbir yere bağlanmaz. Yalnızca `restore.sh`, paketleri geri kurarken Ubuntu depolarını kullanır.
- Yeni açılmış bir sunucuda otomatik güncellemeler apt'yi meşgul ediyorsa 5 dakikaya kadar bekler.

## Test ettik

| Ortam | Sonuç |
|---|---|
| **GitHub Actions, gerçek Ubuntu 24.04.5 sanal makinesi** (her commit) | 41 kontrol geçti. Paket sayısı 1210'dan 1119'a indi. SSH, sudo, DNS, HTTPS ve apt sağlam kaldı. İkinci çalıştırma hiçbir şey değiştirmedi. `restore.sh` kaldırılan her paketi geri kurdu. |
| **ubuntu-server ve ubuntu-standard kurulu temiz sistem** | Paket sayısı 588'den 463'e indi. Korunan paketler yerinde, `apt-get check` temiz. `restore.sh` ile tamamen geri dönüldü, ikinci çalıştırma hiçbir şey değiştirmedi. |

Dürüst not: GitHub'ın sanal makinesi bir bulut sunucusu olduğu için orada cloud-init (doğru olarak) korunuyor.
İkinci test chroot içinde yapıldı; servislerin gerçekten durduğunu ve sistemin açık kaldığını sanal makine testi
doğruluyor.

## Seçenekler

| Parametre | Ne yapar |
|---|---|
| `-n`, `--dry-run` | Hiçbir şeyi değiştirmez, planı gösterir |
| `-y`, `--yes` | Onay sormaz (otomasyon için) |
| `--keep-snap` | snap kalır |
| `--keep-cloud-init` | cloud-init kalır |
| `--remove-cloud-init` | Bulutta çalışıyor görünse bile cloud-init kaldırılır |
| `--keep-fwupd` | fwupd kalır (fiziksel sunucuda firmware güncellemesi için) |
| `--keep-recommends` | apt "önerilen" paket ayarına dokunmaz |
| `--remove-pro` | ubuntu-pro-client da kaldırılır (ESM / Livepatch kullanmıyorsanız) |
| `--force` | Sürüm kontrolünü ve kullanımdaki snap uyarısını atlar |

## Lisans

[MIT](LICENSE). Kendi sorumluluğunuzda kullanın, önce bir test sunucusunda deneyin.

---

## English

**Ubuntu Server Debloat** strips Ubuntu Server 24.04 down to what a server needs: snapd (and blocks it from coming
back), apport / whoopsie / popcon, MOTD and apt ads, ModemManager, udisks2, plymouth, fwupd, and cloud-init / multipath
/ iSCSI when they are not in use.

- **Safe by simulation:** every candidate is simulated with apt first. Anything that would take a protected package
  (ssh, sudo, netplan, systemd-resolved, kernel, bootloader...) with it is kept; if the final plan still touches a
  protected package, the script exits without changing anything. Unreadable apt output stops the script.
- **Reversible:** every run writes a backup and a ready-to-run `restore.sh` under `/var/backups/cemalcloud-debloat/`.
- **Usage:** `sudo ./ubuntu2404-debloat.sh --dry-run`, then `sudo ./ubuntu2404-debloat.sh`.
- **Tested:** every commit runs dry run, debloat, second run and restore on a real Ubuntu 24.04 VM (41 checks;
  1210 to 1119 packages; ssh, sudo, DNS, HTTPS and apt stay healthy).
- **License:** MIT.
