# DepthLab

**DepthLab**, tek bir RGB görüntüden derinlik tahmini (*monocular depth estimation*) elde etmeye yönelik bir görüntü işleme uygulamasıdır. Proje, **Flutter/Dart** ile geliştirilen kullanıcı arayüzünü **Python/FastAPI** tabanlı bir servis ve **YOLO26n-Depth** modeliyle bir araya getirir.

Bu depo, DepthLab uygulamasının kaynak kodunu ve yerel geliştirme amacıyla kullanılan API bileşenlerini içerir.

## Projenin amacı

Bir görüntüdeki sahnelerin derinlik bilgisini tek bir kameradan tahmin etmek; tahminleri renkli derinlik haritalarıyla görselleştirmek ve RGB görüntüyle karşılaştırılabilir şekilde sunmak.

## Teknolojiler

| Bileşen | Teknoloji |
| --- | --- |
| Kullanıcı arayüzü | Flutter, Dart |
| Backend / API | Python, FastAPI |
| Derinlik tahmini | Ultralytics YOLO26n-Depth |
| Görüntü ve video işleme | OpenCV, NumPy, FFmpeg |
| API iletişimi | HTTP / REST |

## Proje yapısı

```text
DepthLab/
├── flutter_app/          # Flutter istemci uygulaması
│   ├── lib/
│   │   └── main.dart     # Uygulama giriş noktası
│   ├── android/
│   ├── ios/
│   ├── web/
│   └── pubspec.yaml
├── backend/
│   └── server.py         # FastAPI servis kodu
└── README.md             # Bu dosya
```

> Bu şema temel dosyaları gösterir; platform dosyalarının tamamı listelenmemiştir.

## Özellikler ve geliştirme durumu

- RGB fotoğraf seçme ve model üzerinden derinlik tahmini oluşturma.
- Orijinal görüntüyle renkli derinlik haritasını karşılaştırma.
- Fotoğraf analizi için işlem süresi ve durum bilgisini görüntüleme.
- Backend tarafında kısa videoları işleyerek derinlik videosu oluşturma.
- Backend tarafında seçili pikselin tahmini derinlik değerini sorgulama.
- Backend tarafında canlı kamera karelerinin analizi için API desteği.

**Not:** Fotoğraf analizi, Flutter arayüzünden API'ye bağlanacak şekilde geliştirilmiştir. Video, canlı kamera, indirme ve diğer ekran özelliklerinin uçtan uca entegrasyonu geliştirme sürümüne bağlıdır. Mevcut sürüm, tamamlanmış bir ürün olarak değil, geliştirme/prototip çalışması olarak değerlendirilmelidir.

## Yerel ortamda çalıştırma

### 1. Gereksinimler

- Python 3.11 veya uyumlu bir Python sürümü
- Flutter SDK ve Dart
- Model dosyası: `yolo26n-depth.pt`
- Gerekli Python paketleri ve Flutter bağımlılıkları

### 2. Backend'i başlatma

Projenin kök klasöründen:

```bash
cd backend
python -m pip install fastapi "uvicorn[standard]" python-multipart ultralytics opencv-python numpy imageio-ffmpeg
```

`yolo26n-depth.pt` model ağırlığını `backend/` klasörüne yerleştirin.

Ardından API'yi başlatın:

```bash
python -m uvicorn server:app --host 127.0.0.1 --port 8000 --reload
```

Servis kontrolü:

- API sağlık kontrolü: http://127.0.0.1:8000/health
- Swagger API belgeleri: http://127.0.0.1:8000/docs

> Model dosyası ve büyük veri setleri bu depoya eklenmemiş olabilir. Backend, model dosyası bulunmadan başlatılamaz.

### 3. Flutter uygulamasını başlatma

Ayrı bir terminalde, projenin kök klasöründen:

```bash
cd flutter_app
flutter pub get
flutter run -d chrome
```

Flutter web çalıştırma hedefinin sisteminizde kurulu ve etkin olması gerekir.

Flutter istemcisinde API adresi `lib/main.dart` içindeki `apiBaseUrl` değişkeniyle tanımlanır. Yerel web testleri için varsayılan adres:

```dart
http://127.0.0.1:8000
```

Telefon, emülatör veya farklı bir bilgisayardan erişimde `127.0.0.1` uygun değildir; API adresi çalıştırma ortamına göre düzenlenmelidir. Ayrıca backend'in ilgili ağ arayüzünden erişilebilir olması gerekir.

## Başlıca API uç noktaları

| Yöntem | Endpoint | İşlev |
| --- | --- | --- |
| `GET` | `/health` | Servis durumunu kontrol eder |
| `POST` | `/predict` | Fotoğraftan renkli depth PNG üretir |
| `GET` | `/depth-at/{result_id}` | Fotoğraftaki `(x, y)` pikselinin tahmini derinliğini sorgular |
| `POST` | `/predict-video` | Kısa videodan depth videosu oluşturur |
| `GET` | `/results/{result_id}.mp4` | İşlenmiş videoyu sunar |
| `GET` | `/video-depth-at/{result_id}` | İşlenmiş videoda kare/piksel derinliğini sorgular |
| `POST` | `/predict-live` | Kamera karesi için depth tahmini üretir |

**Mevcut backend prototipindeki sınırlar:** fotoğraf en fazla 12 MB, video en fazla 50 MB ve 10 saniye; video analizi yaklaşık en fazla 4 FPS örnekleme ile yürütülür. Bu sınırlar servis kodundan değiştirilebilir.

## Model ve sonuçlar hakkında

DepthLab'in API örnekleri **önceden eğitilmiş (pretrained)** `YOLO26n-Depth` modelini kullanır. Renkli depth görseli, tahmini derinlik verisinin görselleştirilmiş halidir; sayısal derinlik haritası ise backend tarafında ayrıca saklanır.

Model tahminleri, bağımsız ve güvenilir *ground truth* ile karşılaştırılmadıkça ölçüm doğruluğu garanti edilmiş kabul edilmemelidir. Projede model değerlendirme ve fine-tuning çalışmaları ayrıca yürütülmektedir.

## Geliştirme notları

- Bu API, kimlik doğrulama içermeyen **yerel geliştirme prototipidir**. Doğrudan internete açılmamalıdır.
- Model ağırlıkları, veri setleri, geçici sonuçlar ve makineye özel dosyalar kaynak kod deposundan ayrı tutulmalıdır.
- Backend'in oluşturduğu `results/` klasörü çalışma çıktıları içindir; sürüm kontrolüne eklenmesi gerekmez.

---

**Proje:** DepthLab  
**Kapsam:** Monocular Depth Estimation • Flutter Application • Python Backend
