<div align="center">

```
  ____                     _       _                 _
 / ___|___ _ __ ___   __ _| |  ___| | ___  _   _  __| |
| |   / _ \ '_ ` _ \ / _` | | / __| |/ _ \| | | |/ _` |
| |__|  __/ | | | | | (_| | || (__| | (_) | |_| | (_| |
 \____\___|_| |_| |_|\__,_|_(_)___|_|\___/ \__,_|\__,_|
```

# Ubuntu Server 24.04 Debloat

**snap, telemetri ve gereksiz servisleri kaldırır. Kritik bir paketi etkileyecekse hiçbir şey yapmadan durur.**

[![ci](https://github.com/cemal-demirci/ubuntu-server-debloat/actions/workflows/ci.yml/badge.svg)](https://github.com/cemal-demirci/ubuntu-server-debloat/actions/workflows/ci.yml)
![license](https://img.shields.io/badge/license-MIT-blue)

[cemal.cloud](https://cemal.cloud)

</div>

---

Ubuntu Server 24.04 LTS'i sunucuda gerçekten işe yarayan paketlere indirir. Kaldırmadan önce her adımı apt ile simüle eder, kritik bir paket etkilenecekse hiçbir şey yapmadan çıkar.

## İndirme

```bash
curl -fsSLO https://raw.githubusercontent.com/cemal-demirci/ubuntu-server-debloat/main/ubuntu2404-debloat.sh
chmod +x ubuntu2404-debloat.sh
```

## Kullanım

```bash
sudo ./ubuntu2404-debloat.sh --dry-run     # planı göster
sudo ./ubuntu2404-debloat.sh               # onay ister
sudo ./ubuntu2404-debloat.sh -y            # onaysız (otomasyon)
```

| Parametre | Etki |
|---|---|
| `-n`, `--dry-run` | Hiçbir şeyi değiştirmez |
| `-y`, `--yes` | Onay sormaz |
| `--keep-snap` | snapd kalır |
| `--keep-cloud-init` | cloud-init kalır |
| `--remove-cloud-init` | Bulutta çalışıyor görünse bile cloud-init kaldırılır |
| `--keep-fwupd` | fwupd kalır (fiziksel sunucuda firmware güncellemesi için) |
| `--keep-recommends` | apt "Recommends" kapatılmaz |
| `--remove-pro` | ubuntu-pro-client da kaldırılır (ESM / Livepatch kullanmıyorsanız) |
| `--force` | Sürüm kontrolünü ve kullanımdaki snap uyarısını atlar |

## Ne kaldırılır

| Grup | Paketler |
|---|---|
| Telemetri / hata raporlama | apport, whoopsie, popularity-contest, ubuntu-report |
| MOTD ve dışarı bağlanan | landscape-common, update-notifier-common, pollinate |
| Sunucuda gereksiz servisler | ModemManager, udisks2, packagekit-tools, plymouth, bolt, kerneloops, lxd-installer, sosreport, fwupd |
| snap | Tüm snap'ler, snapd, `/snap` ve `/var/lib/snapd`. snapd apt pin ile tekrar kurulamaz hale gelir. |
| Koşullu | **cloud-init** (sadece gerçek bir bulut datasource'u yoksa), **multipath-tools** (multipath map yoksa), **open-iscsi** (aktif iSCSI oturumu yoksa) |

Ayrıca MOTD ve apt reklamları susturulur, journald 500 MB ile sınırlanır, apt "Recommends" kapatılır, `needrestart` her apt çalışmasında soru sormak yerine sadece listeler.

## Ne korunur

`openssh-server`, `sudo`, `netplan.io`, `systemd-resolved`, `unattended-upgrades` (güvenlik güncellemeleri), `ubuntu-pro-client` (sadece reklamı susturulur), kernel ve bootloader paketleri, LVM / RAID / LUKS araçları, `software-properties-common`.

Ayrıca kaldırılan bir paketin bağımlılığı olarak gelmiş ama tek başına da sık kullanılan araçlar (`jq`, `bc`, `curl`, `wget`, `rsync`, `tmux`, `htop`, `git`, `vim-tiny`, `nano`, `python3`, `secureboot-db` vb.) kuruluysa korunur.

## Güvenlik mekanizması

1. Her aday paket tek tek simüle edilir. Kaldırılması korunan bir paketi de götürecekse o paket plandan çıkarılır. Örnek: stok 24.04'te `packagekit` kaldırılırsa `software-properties-common` da gider, bu yüzden `packagekit` kalır.
2. Tüm plan bir kez daha simüle edilir. Korunan bir paket etkileniyorsa script hiçbir şey yapmadan çıkar.
3. Simülasyon çıktısı okunamazsa (apt hatası, kilit) script güvenli tarafta kalır ve durur.
4. `apt autoremove` sadece simülasyonu temizse çalışır.
5. `/proc` bağlı değilse (örneğin çıplak bir chroot) script hiç başlamaz.

## Yedek ve geri alma

Her çalıştırma `/var/backups/cemalcloud-debloat/<tarih-saat>/` klasörüne yazar:

- `dpkg-selections.txt`, `apt-manual.txt`: kaldırmadan önceki paket durumu
- `snap-list.txt`: kaldırılan snap'ler
- `debloat.log`: tam çıktı
- `restore.sh`: config değişikliklerini geri alır, kaldırılan paketleri (bağımlı olarak gidenler dahil) tekrar kurar

```bash
sudo /var/backups/cemalcloud-debloat/<tarih-saat>/restore.sh
```

## Test

Her commit'te GitHub Actions'ta gerçek bir Ubuntu 24.04 VM'de (systemd ile açılmış) uçtan uca çalıştırılır: dry-run hiçbir paketi değiştirmez, gerçek çalıştırmadan sonra SSH, sudo, DNS, HTTPS ve apt sağlam kalır, ikinci çalıştırma hiçbir şey değiştirmez ve `restore.sh` kaldırılan her paketi geri kurar.

Ayrıca tam `ubuntu-server` + `ubuntu-standard` kurulumu üzerinde elle test edildi: 588 paketten 463'e indi, korunan paketler yerinde kaldı, `apt-get check` temiz, `restore.sh` ile tamamen geri dönüldü, ikinci çalıştırmada değişiklik yapılmadı.

## Prensipler

1. **Önce göster.** Dry-run modu ile neyin değişeceğini önce görün.
2. **Yedek al.** Değişiklikten önce yedek ve geri alma dosyası yazılır.
3. **Geri alınabilir.** Her değişikliğin geri dönüş yolu var.
4. **Kritik olana dokunma.** Sistemi ayakta tutan parçalar korunur.
5. **Sessiz hata yok.** Kontrol yapılamıyorsa script güvenli tarafta kalır ve durur.

## Sorumluluk

Bu scriptler sistem ayarlarını değiştirir ve yazılım kaldırır. Kendi sorumluluğunuzda kullanın, önce test ortamında deneyin. Kurumsal yönetilen cihazlarda BT ekibinizle konuşmadan çalıştırmayın.

## Diğer Cemal.cloud araçları

| Repo | |
|---|---|
| [`win11-debloat`](https://github.com/cemal-demirci/win11-debloat) | Copilot, Recall, reklam ve telemetriyi kaldıran, her değişikliği geri alınabilir şekilde kaydeden Windows 11 temizliği. |
| [`k8s-debloat`](https://github.com/cemal-demirci/k8s-debloat) | Traefik ve ServiceLB olmadan sade k3s kurulumu ve her cluster için varsayılanı dry-run olan temizlik scripti. |
| [`ffmpeg-broadcast`](https://github.com/cemal-demirci/ffmpeg-broadcast) | Yayıncılık için sade FFmpeg build'i ve 19 hazır yayın preseti: XDCAM, AVC-Intra, IMX, ProRes, DNxHD, DVB, HLS, SRT. |

## Lisans

[MIT](LICENSE)

---

<details>
<summary><b>English</b></summary>

Ubuntu Server 24.04 debloat: snapd (blocked from coming back), apport/whoopsie/popcon, MOTD and apt ads, ModemManager, udisks2, fwupd, plymouth and cloud-init / multipath / iSCSI when they are not in use. Every candidate is simulated with apt first; anything that would take a protected package (ssh, sudo, netplan, systemd-resolved, kernel, bootloader...) with it is kept, and if the final plan still touches a protected package the script exits without changing anything. A backup and a ready-to-run `restore.sh` are written for every run. Waits up to 5 minutes for the apt lock (fresh servers running unattended-upgrades).

```bash
sudo ./ubuntu2404-debloat.sh --dry-run
sudo ./ubuntu2404-debloat.sh
sudo /var/backups/cemalcloud-debloat/<timestamp>/restore.sh
```

CI runs a dry run, a real run, a second run and the restore on a real Ubuntu 24.04 VM for every commit.

</details>
