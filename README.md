# Ubuntu Server 24.04 Debloat · Cemal.cloud

Ubuntu Server 24.04'ü bir sunucunun gerçekten ihtiyaç duyduğu paketlere indiren bash scripti. Kritik bir paketi bozacaksa hiçbir şey yapmadan durur.

[![ci](https://github.com/cemal-demirci/ubuntu-server-debloat/actions/workflows/ci.yml/badge.svg)](https://github.com/cemal-demirci/ubuntu-server-debloat/actions/workflows/ci.yml)
![license](https://img.shields.io/badge/license-MIT-blue)

## Neden?

Ubuntu Server kutudan çıktığı haliyle sunucuda işe yaramayan birçok şeyle gelir: snap, hata raporu ve kullanım istatistiği gönderen servisler, her girişte reklam gösteren karşılama mesajı, modem ve USB disk yöneticileri, firmware güncelleyici. Bunlar RAM ve disk harcar, arka planda dışarıya bağlanır ve saldırı yüzeyini büyütür.

Bunları elle kaldırmak risklidir. `apt purge` ile tek bir paketi silmek, bağımlılık zinciri yüzünden hiç beklemediğiniz paketleri de götürebilir. Bu script her adımı önce simüle eder, SSH, ağ veya kernel gibi kritik bir paket etkilenecekse o adımı yapmaz.

## Hızlı başlangıç

```bash
curl -fsSLO https://raw.githubusercontent.com/cemal-demirci/ubuntu-server-debloat/main/ubuntu2404-debloat.sh
chmod +x ubuntu2404-debloat.sh

sudo ./ubuntu2404-debloat.sh --dry-run   # 1. ne yapacağını görün (hiçbir şey değişmez)
sudo ./ubuntu2404-debloat.sh             # 2. onaylayıp uygulayın
sudo reboot
```

## Ne değişir?

| | |
|---|---|
| **Kaldırılır** | snap ve tüm snap paketleri (tekrar kurulması da engellenir), apport, whoopsie ve popularity-contest (telemetri), landscape ve karşılama mesajı reklamları, pollinate, ModemManager, udisks2, plymouth, fwupd, lxd-installer, sosreport |
| **Kullanılmıyorsa kaldırılır** | cloud-init (gerçek bir bulut ortamı algılanmazsa), multipath-tools (multipath disk yoksa), open-iscsi (aktif iSCSI bağlantısı yoksa) |
| **Ayarlanır** | Karşılama mesajı ve apt reklamları susturulur, sistem günlüğü 500 MB ile sınırlanır, apt "önerilen" paketleri kendiliğinden kurmaz, needrestart her güncellemede soru sormaz |
| **Dokunulmaz** | SSH, sudo, netplan, systemd-resolved, kernel ve bootloader, LVM / RAID / LUKS araçları, otomatik güvenlik güncellemeleri, ubuntu-pro-client |

Kaldırılan bir paketle birlikte gelmiş ama tek başına da sık kullanılan araçlar (`jq`, `bc`, `curl`, `git`, `htop`, `tmux` gibi) kuruluysa yerinde kalır.

## Nasıl güvenli kalıyor?

1. Her paket kaldırılmadan önce tek tek simüle edilir. Kaldırılması korunan bir paketi de götürecekse o paket listeden çıkarılır.
2. Tüm plan bir kez daha simüle edilir. Korunan bir paket etkileniyorsa script hiçbir şey yapmadan çıkar.
3. apt'nin cevabı okunamazsa (kilit, hata) script durur. Emin olamadığı durumda devam etmez.
4. Yeni açılmış bir sunucuda otomatik güncellemeler apt'yi meşgul ediyorsa 5 dakikaya kadar bekler.

## Geri alma

Her çalıştırma `/var/backups/cemalcloud-debloat/<tarih-saat>/` altına bir yedek ve hazır bir geri alma scripti bırakır:

```bash
sudo /var/backups/cemalcloud-debloat/<tarih-saat>/restore.sh
```

Yapılan ayarlar geri alınır, kaldırılan paketler yeniden kurulur.

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

## Nasıl test ediliyor?

Her değişiklikte GitHub Actions, script'i gerçek bir Ubuntu 24.04 sanal makinesinde çalıştırır ve şunları kontrol eder: dry-run hiçbir paketi değiştirmiyor, gerçek çalıştırmadan sonra SSH, sudo, DNS, internet ve apt sağlam kalıyor, ikinci çalıştırma hiçbir şey değiştirmiyor, `restore.sh` kaldırılan her paketi geri kuruyor.

## Lisans

[MIT](LICENSE). Kendi sorumluluğunuzda kullanın, önce bir test sunucusunda deneyin.

---

<details>
<summary><b>English</b></summary>

Ubuntu Server 24.04 debloat: snapd (blocked from coming back), apport/whoopsie/popcon, MOTD and apt ads, ModemManager, udisks2, fwupd, plymouth and cloud-init / multipath / iSCSI when they are not in use. Every candidate is simulated with apt first; anything that would take a protected package (ssh, sudo, netplan, systemd-resolved, kernel, bootloader...) with it is kept, and if the final plan still touches a protected package the script exits without changing anything. A backup and a ready-to-run `restore.sh` are written for every run. Waits up to 5 minutes for the apt lock on freshly booted servers.

```bash
sudo ./ubuntu2404-debloat.sh --dry-run
sudo ./ubuntu2404-debloat.sh
sudo /var/backups/cemalcloud-debloat/<timestamp>/restore.sh
```

CI runs a dry run, a real run, a second run and the restore on a real Ubuntu 24.04 VM for every commit.

</details>
