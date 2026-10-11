# Hacı OS 0.2.0 — Yerel Orbit

iPhone X / iOS 16.4.1 / Dopamine rootless / ElleKit için SpringBoard tweak'i.
0.1.1 cihaz denemesinde overlay SBHomeScreenWindow'a doğru eklendi ve ikonları
örttü; WebContent süreci sürekli sonlandı, sayfa çizilemedi ve ayrı katmandaki
dock üstte kaldı. 0.2.0 arayüzü UIKit + Core Animation ile yeniden yazar.
WebKit, JavaScript köprüsü, WebContent süreci ve yeniden yükleme döngüsü kaldırıldı.

`orbit-prototip.html` yalnız depodaki tasarım referansıdır. Paket HTML veya
`layout/` kaynakları içermez. Yerel arayüz prototipin siyah-beyaz görünümünü,
üstten %53 kara delik merkezini, yörünge ölçülerini, 50 pt ikonlarını ve 24×24
SVG yollarını UIBezierPath ile korur. Photon ring, glow ve farklı hızlarda dönen
eliptik birikim diskleri Core Animation katmanlarıdır; shader görünümünün birebir
piksel karşılığı hedeflenmez.

İç yörüngede Hacı, Claude, Kamera, Safari ve Mesajlar saat yönünde; dış yörüngede
Telefon, Fotoğraflar, Notlar, Mail, WhatsApp, Dosyalar ve Ayarlar ters yönde döner.
Her halka tek container layer ile döner; ikonların eşzamanlı ters dönüşü onları
dik tutar. Dokunma ve dokunmayı bırakma, model frame yerine presentation layer
konumuyla hesaplanır. Dokunulan ikon kısa parlar; ad etiketi 1,6 saniye görünür.
Claude `https://claude.ai` açar; Hacı ve “Hacı'ya sor” kapsülü `YAKINDA` gösterir.
Önceki bundle ID'ler korunur; başarısız açma `AÇILAMADI` gösterir.

Saat `HH:mm`, tarih `tr_TR` uzun gün adıyla büyük harf gösterilir. Saat zamanlayıcısı
bir sonraki dakika sınırından başlayarak 60 saniyede bir çalışır. Uygulama öne
geçince, ana ekran/pencere görünmezken, ekran kapalıyken veya Orbit gizlenince
scene layer `speed/timeOffset/beginTime` ile duraklatılır; kapsül nabzı dahil tüm
CA animasyonları birlikte donar. Saat ve kısa etiket zamanlayıcıları iptal edilir.
Görünür olunca saat hemen yenilenir ve animasyonlar kaldıkları yerden devam eder.
Reduce Motion başlangıçta açıksa döngüsel animasyonlar kurulmaz.

Overlay SBHomeScreenWindow'da kalır. Varsa SBDockView, SBFloatingDockView ve
SBIconListPageControl ayrı, sınıf ve metot kontrolü yapılan hook gruplarıyla
Orbit görünürken `alpha=0` ve `userInteractionEnabled=NO` olur. Üçlü dokunma,
disabled veya uygulamaya geçişte SpringBoard'un son alpha/etkileşim değerleri
geri yüklenir. Bu sınıflardan birinin bulunmaması diğerlerini engellemez.

## Kurtarma

**Saate bir saniye içinde üç kez dokunun.** Normal ikonlar, dock ve sayfa
göstergesi geri gelir; Orbit bir sonraki respring'e kadar gizli kalır.

Kalıcı kapatma için Filza ile şu konumda boş dosya veya klasör oluşturun:

```text
/var/jb/var/mobile/Library/Preferences/com.yigit.hacios.disabled
```

Respring sırasında işaret varsa hook'lar kurulmaz. Çalışırken oluşturulursa bir
sonraki görünürlük/layout kontrolünde overlay kapanır ve dock geri yüklenir.
Yeniden etkinleştirmek için işareti kaldırıp respring yapın. SpringBoard açılmıyorsa
Dopamine'in tweak yüklemeyi kapatma / güvenli mod seçeneğiyle açıp kapatma
işaretini oluşturun veya paketi kaldırın.

## Günlük ve doğrulama

Sistem günlüğündeki `[HaciOS]` kayıtları ayrıca
`/var/jb/var/mobile/Library/Logs/HaciOS.log` dosyasına yazılır; 200 KB sınırında
en yeni yaklaşık 100 KB tutulur. Kayıtlar başlangıç, yeni attach, görünürlük/
duraklama değişimi, açma sonucu ve hatayla sınırlıdır. Tekrarlayan hata türleri
bir kez kaydedilir; kare, layout veya bildirim başına kayıt üretilmez.

Mevcut paket hattı sürümü `control` dosyasından alır: `v0.2.0-build.<run_number>`.
Sabit indirme dosyası `HaciOS-latest.deb` olarak kalır. Kurulumdan sonra respring yapın.

Bu değişiklikte git, ağ veya derleme çalıştırılmadı; 0.2.0 cihazda test edilmedi.
Cihazda özellikle hareketli ikonların dokunması, dock/sayfa göstergesi geri dönüşü,
uygulama/ekran kapatma geçişleri ve GPU/gölge maliyeti doğrulanmalı. Özel API'lerin
sınıf ve imzaları iOS sürümüne bağlıdır. `hasBlankedScreen` için mevcut 0=açık,
sıfır dışı=duraklat davranışı korunur; bildirim okunamazsa arayüz durağan kalır.
Void açma API'sinin `accepted` sonucu isteğin iletildiğini belirtir; uygulamanın
gerçekten açıldığını doğrulamaz.
