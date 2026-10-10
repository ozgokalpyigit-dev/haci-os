# Hacı OS 0.1.0 — Aşama 3a

iPhone X / iOS 16.4.1 / Dopamine rootless / ElleKit için SpringBoard tweak'i.
Ana ekranda ikonları ve dock'u örten, yerel WKWebView içinde tam ekran **Hacı
Orbit** gösterir. Önceki geçici kapsül kaldırılmıştır. WhatsApp ve Dosyalar ayrı
ikonlardır; Claude `https://claude.ai` açar, Hacı şimdilik `YAKINDA` gösterir.

`orbit-prototip.html` tasarım kaynağıdır; paketlenen kopyası
`layout/Library/Application Support/HaciOS/orbit.html` konumundadır. Theos'un
`rootless` paket şeması `layout/` içeriğini kurulum öneki altına taşır; bu nedenle
`layout/` içine ikinci bir `var/jb` eklenmez. Telefonda HTML yolu
`/var/jb/Library/Application Support/HaciOS/orbit.html` olur ve tweak yolu
`ROOT_PATH_NS` ile çözer. HTML güncellenirken paketlenen kopya da güncellenmelidir.

Uygulama ön plandayken, ana ekran görünmezken veya ekran kapalıyken animasyon,
saat zamanlayıcısı ve CSS nabız animasyonu duraklar. Ana ekrana dönünce sürer.
Tek overlay oluşturulur; tekrar görünme olayları aynı görünümü kullanır. Ana ekran
sınıfı, `frontDisplayDidChange:` veya ekran bildirimi kullanılamıyorsa Orbit
başlatılmaz. Kritik kayıtlar `[HaciOS]` önekiyle sistem günlüğüne yazılır.

## Kurtarma

**Saate bir saniye içinde üç kez dokunun.** Normal ikonlar ve dock geri gelir;
Orbit bir sonraki respring'e kadar gizli kalır.

Kalıcı kapatma için Filza ile önceki sürümdeki konumda boş bir dosya oluşturun:

```text
/var/jb/var/mobile/Library/Preferences/com.yigit.hacios.disabled
```

Respring sonrasında dosya varken hook'lar etkinleşmez. Yeniden etkinleştirmek
için dosyayı silip respring yapın. SpringBoard açılmıyorsa Dopamine'in tweak
yüklemeyi kapatma / güvenli mod seçeneğiyle açıp kapatma dosyasını oluşturun
veya paketi kaldırın.

## Paketleme

Mevcut GitHub Actions hattı `main` push veya **Run workflow** ile çalışır;
`arm64` ve `arm64e` için rootless paket üretir. Artifact adı ve release
tag/adı sürümü `control` dosyasından alır: `v0.1.0-build.<run_number>`.
Sabit indirme dosyası `HaciOS-latest.deb` olarak kalır. Kurulumdan sonra respring
yapın. Önceki sürümün derleme ve telefon doğrulaması bu yeni kodun doğrulaması
sayılmaz; Aşama 3a değişiklikleri bu düzenleme sırasında derlenmemiş veya
test edilmemiştir.

Özel SpringBoard API'leri, dock'un aynı ana ekran penceresinde bulunması ve
`com.apple.springboard.hasBlankedScreen` bildirim durumunun sıfır dışında
ekran kapalı anlamına gelmesi iOS 16.4.1 cihazında ayrıca doğrulanmalıdır.
Void dönen bir açma API'sinde günlükteki `accepted`, isteğin iletildiğini belirtir;
uygulamanın gerçekten açıldığını doğrulamaz.
