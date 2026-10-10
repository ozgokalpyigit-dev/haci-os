# Hacı OS 0.0.1

iPhone X, iOS 16.4.1 ve Dopamine **rootless** jailbreak (ElleKit) için Theos
SpringBoard tweak'i. Aşama 2'nin ilk sürümüdür: SpringBoard açılışından 2 saniye
sonra üst ortada siyah, ince beyaz kenarlı `HACI OS 0.0.1` kapsülü gösterir;
yaklaşık 3 saniye sonra kaybolur. Dokunmaları engellemez.

Derleme yalnızca GitHub Actions'ta yapılır. `main` dalına push veya Actions →
**Build Hacı OS → Run workflow** ile başlatılır. `macos-15` üzerinde resmî Theos
alt modülleriyle kurulur; resmî SDK deposundaki en yeni 16.x, yoksa 15.x SDK
seçilir. `make package FINALPACKAGE=1 THEOS_PACKAGE_SCHEME=rootless` iki mimariyi
(`arm64`, `arm64e`) derler. Runner kaynaklı sorun olursa workflow'daki runner
`macos-14` olarak değiştirilebilir. Çıktı artifact ve
`v0.0.1-build.<run_number>` sürümü olarak yayımlanır. Yerel derleme veya cihaz
testi yapılmamıştır; ilk Actions çalıştırması derleme hattını doğrulayacaktır.

## Telefona kurulum

1. Safari'de kendi GitHub deponuzun
   `https://github.com/<sahip>/<depo>/releases/latest/download/HaciOS-latest.deb`
   adresini açın. `<sahip>` ve `<depo>` alanlarını değiştirin.
2. İndirilen paketi Filza ile açıp kurun; paket yöneticiniz yerel `.deb` açmayı
   destekliyorsa Sileo ile de kurabilirsiniz. ElleKit önceden kurulu olmalıdır;
   paketin `mobilesubstrate` bağımlılığını sağlar.
3. Respring yapın. Sistem günlüğünde `[HaciOS] loaded` ve etiket gösterildiğinde
   `[HaciOS] badge shown` kayıtları beklenir.

## Kurtarma ve güvenli mod

Filza ile aşağıdaki konumda boş bir dosya oluşturun (dosyanın varlığı yeterlidir):

```text
/var/jb/var/mobile/Library/Preferences/com.yigit.hacios.disabled
```

Ardından respring yapın. Dosya varken Hacı OS hook'u ve gösterimi etkinleşmez.
Yeniden etkinleştirmek için dosyayı silip respring yapın. Theos `rootless.h`
mevcutsa yol `ROOT_PATH_NS` ile jbroot'a uyarlanır; yoksa `/var/jb` kullanılır.

SpringBoard normal açılmıyorsa jailbreak'in tweak yüklemeyi kapatma / güvenli
mod seçeneğiyle açın, Filza üzerinden kapatma dosyasını oluşturun veya Hacı OS
paketini kaldırın. Objective-C istisna koruması her tür çökme ve açılış döngüsünü
önleyemez; bu ilk sürümün cihaz uyumluluğu ayrıca doğrulanmalıdır.

`orbit-prototip.html` sonraki aşamanın tasarımıdır; bu sürümde kullanılmaz.
