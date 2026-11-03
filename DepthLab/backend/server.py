"""DepthLab - pretrained YOLO26n-Depth photo and short-video API.

Local development only. Do not expose to untrusted networks without adding auth.
"""
from __future__ import annotations

import base64
import math
import re
import tempfile
from pathlib import Path
from uuid import uuid4

import cv2
import imageio_ffmpeg
import numpy as np
from fastapi import FastAPI, File, Form, HTTPException, UploadFile, Query
from fastapi.concurrency import run_in_threadpool
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import FileResponse, Response
from ultralytics import YOLO
from ultralytics.utils.plotting import colorize_depth

ROOT = Path(__file__).resolve().parent
MODEL_PATH = ROOT / "yolo26n-depth.pt"
RESULTS = ROOT / "results"
RESULTS.mkdir(exist_ok=True)

MAX_VIDEO_BYTES = 50 * 1024 * 1024
MAX_VIDEO_SECONDS = 10.0
VIDEO_MAX_FPS = 4.0  # Hızlı ilk test: saniyede en fazla 4 kare analiz edilir.
VIDEO_MAX_WIDTH = 640

app = FastAPI(title="DepthLab YOLO26-Depth")
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],  # SADECE yerel geliştirme için; gerçek dağıtımda kısıtlayın.
    allow_credentials=False,
    allow_methods=["GET", "POST"],
    allow_headers=["*"],
    expose_headers=["X-Depth-Id", "X-Image-Width", "X-Image-Height"],
)
model = YOLO(str(MODEL_PATH))


@app.get("/health")
def health():
    return {"status": "ok", "model": MODEL_PATH.name}


def predict_photo(image_bytes: bytes) -> tuple[bytes, str, int, int]:
    """Keep the real numerical depth; the PNG alone cannot recover meters."""
    image = cv2.imdecode(np.frombuffer(image_bytes, dtype=np.uint8), cv2.IMREAD_COLOR)
    if image is None:
        raise HTTPException(status_code=400, detail="Gecerli bir fotograf secin.")
    image_h, image_w = image.shape[:2]
    result = model.predict(source=image, imgsz=768, verbose=False)[0]
    depth = np.asarray(result.depth.data.cpu().numpy(), dtype=np.float32)
    depth = np.squeeze(depth)
    if depth.ndim != 2:
        raise HTTPException(status_code=500, detail="Model 2B depth haritasi donmedi.")
    # Map values and colored output to the SAME pixel grid as the original.
    if depth.shape != (image_h, image_w):
        depth = cv2.resize(depth, (image_w, image_h), interpolation=cv2.INTER_LINEAR)
    colored = colorize_depth(depth, cmap="spectral")
    ok, png = cv2.imencode(".png", colored)
    if not ok:
        raise HTTPException(status_code=500, detail="Depth PNG uretilemedi.")
    result_id = uuid4().hex
    # Local prototype: files are kept for subsequent clicks; do not share
    # this directory publicly, and clean up old .npy files as needed.
    np.save(RESULTS / f"{result_id}.npy", depth, allow_pickle=False)
    return png.tobytes(), result_id, image_w, image_h


@app.post("/predict")
async def predict(file: UploadFile = File(...)):
    try:
        raw = await file.read(12 * 1024 * 1024 + 1)
        if len(raw) > 12 * 1024 * 1024:
            raise HTTPException(status_code=413, detail="Fotograf 12 MB'dan kucuk olmali.")
        png, result_id, image_w, image_h = await run_in_threadpool(predict_photo, raw)
        return Response(
            content=png,
            media_type="image/png",
            headers={
                "X-Depth-Id": result_id,
                "X-Image-Width": str(image_w),
                "X-Image-Height": str(image_h),
                "Cache-Control": "no-store",
            },
        )
    finally:
        await file.close()


@app.get("/depth-at/{result_id}")
def depth_at(result_id: str, x: int = Query(ge=0), y: int = Query(ge=0)):
    """Return the predicted depth of the ORIGINAL image pixel (x,y)."""
    if not re.fullmatch(r"[a-f0-9]{32}", result_id):
        raise HTTPException(status_code=404, detail="Depth sonucu bulunamadi.")
    path = RESULTS / f"{result_id}.npy"
    if not path.is_file():
        raise HTTPException(status_code=404, detail="Depth sonucu bulunamadi.")
    depth = np.load(path, mmap_mode="r", allow_pickle=False)
    height, width = depth.shape
    if x >= width or y >= height:
        raise HTTPException(status_code=422, detail="Piksel goruntu disinda.")
    value = float(depth[y, x])
    if not math.isfinite(value) or value <= 0:
        return {"x": x, "y": y, "valid": False, "depth_m": None}
    return {"x": x, "y": y, "valid": True, "depth_m": round(value, 4)}


def process_video(raw: bytes, extension: str) -> dict:
    result_id = uuid4().hex
    output = RESULTS / f"{result_id}.mp4"
    writer = None
    capture = None
    processed = 0
    depth_frames: list[np.ndarray] = []
    source_temp_path = None
    try:
        # OpenCV'nin dosyayi dogru cozebilmesi icin orijinal uzantiyi koru.
        with tempfile.NamedTemporaryFile(suffix=extension, delete=False) as source:
            source.write(raw)
            source_temp_path = Path(source.name)

        capture = cv2.VideoCapture(str(source_temp_path))
        if not capture.isOpened():
            raise HTTPException(status_code=400, detail="Video acilamadi veya codec desteklenmiyor.")

        fps = capture.get(cv2.CAP_PROP_FPS)
        frame_count = capture.get(cv2.CAP_PROP_FRAME_COUNT)
        if not math.isfinite(fps) or fps < 1 or fps > 240:
            raise HTTPException(status_code=400, detail="Videonun FPS bilgisi okunamadi.")
        if math.isfinite(frame_count) and frame_count > 0 and frame_count / fps > MAX_VIDEO_SECONDS + 0.2:
            raise HTTPException(status_code=413, detail="Ilk test icin en fazla 10 saniyelik video secin.")

        sample_every = max(1, int(round(fps / VIDEO_MAX_FPS)))
        output_fps = fps / sample_every
        index = 0

        while True:
            has_frame, frame = capture.read()
            if not has_frame:
                break
            if index / fps > MAX_VIDEO_SECONDS:
                raise HTTPException(status_code=413, detail="Ilk test icin en fazla 10 saniyelik video secin.")
            if index % sample_every == 0:
                h, w = frame.shape[:2]
                new_w = min(w, VIDEO_MAX_WIDTH)
                new_h = max(2, int(round(h * new_w / w)))
                # YUV420p icin cift boyutlar.
                new_w -= new_w % 2
                new_h -= new_h % 2
                frame = cv2.resize(frame, (new_w, new_h), interpolation=cv2.INTER_AREA)
                depth = np.asarray(
                    model.predict(source=frame, imgsz=512, verbose=False)[0]
                    .depth.data.cpu().numpy(), dtype=np.float32
                ).squeeze()
                if depth.ndim != 2:
                    raise HTTPException(status_code=500, detail="Model video icin 2B depth dondurmedi.")
                if depth.shape != (new_h, new_w):
                    depth = cv2.resize(depth, (new_w, new_h), interpolation=cv2.INTER_LINEAR)
                # Her renkli video karesinin SAYISAL depth haritasini da sakliyoruz.
                # Sonradan secilen piksel metre cinsinden sorgulanabilecek.
                depth_frames.append(depth.copy())
                # Tek renk (mavi/kirmizi) doygunlugunu onlemek icin
                # sabit 0-50 m araligi yerine otomatik normalizasyon kullan.
                # Fotograf analizindeki gorunume yakin sonuc verir.
                if processed == 0:
                    valid_depth = depth[np.isfinite(depth) & (depth > 0)]
                    if valid_depth.size:
                        p2, p50, p98 = np.percentile(valid_depth, [2, 50, 98])
                        print(
                            f"Video depth (ilk kare): p2={p2:.3f} m, "
                            f"median={p50:.3f} m, p98={p98:.3f} m",
                            flush=True,
                        )
                    else:
                        print("UYARI: Ilk karede gecerli depth verisi yok!", flush=True)
                colored_bgr = colorize_depth(depth, cmap="spectral")
                if colored_bgr.shape[:2] != (new_h, new_w):
                    colored_bgr = cv2.resize(colored_bgr, (new_w, new_h))
                if writer is None:
                    writer = imageio_ffmpeg.write_frames(
                        str(output),
                        size=(new_w, new_h),
                        pix_fmt_in="rgb24",
                        pix_fmt_out="yuv420p",
                        fps=output_fps,
                        codec="libx264",
                        macro_block_size=2,
                        output_params=["-movflags", "+faststart"],
                    )
                    writer.send(None)
                rgb = cv2.cvtColor(colored_bgr, cv2.COLOR_BGR2RGB)
                writer.send(np.ascontiguousarray(rgb).tobytes())
                processed += 1
            index += 1

        if processed == 0:
            raise HTTPException(status_code=400, detail="Videodan kare okunamadi.")
        writer.close()
        writer = None
        if not output.exists() or output.stat().st_size == 0:
            raise HTTPException(status_code=500, detail="MP4 sonucu olusturulamadi.")
        # (Kare, Y, X) sirasi: ffmpeg'e gonderilen kare sirasi ile ayni.
        np.save(RESULTS / f"{result_id}_video.npy", np.stack(depth_frames), allow_pickle=False)
        return {
            "status": "ok",
            "video_depth_id": result_id,
            "depth_width": new_w,
            "depth_height": new_h,
            "video_url": f"/results/{result_id}.mp4",
            "processed_frames": processed,
            "result_fps": round(output_fps, 2),
            "color_scale": "auto-disparity-per-frame",
        }
    except Exception:
        output.unlink(missing_ok=True)
        (RESULTS / f"{result_id}_video.npy").unlink(missing_ok=True)
        raise
    finally:
        if writer is not None:
            try:
                writer.close()
            except Exception:
                pass
        if capture is not None:
            capture.release()
        if source_temp_path is not None:
            source_temp_path.unlink(missing_ok=True)


@app.post("/predict-video")
async def predict_video(file: UploadFile = File(...)):
    try:
        ext = Path(file.filename or "clip.mp4").suffix.lower()
        if ext not in {".mp4", ".mov", ".avi", ".mkv", ".webm"}:
            raise HTTPException(status_code=415, detail="MP4, MOV, AVI, MKV veya WebM secin.")
        raw = await file.read(MAX_VIDEO_BYTES + 1)
        if len(raw) > MAX_VIDEO_BYTES:
            raise HTTPException(status_code=413, detail="Video 50 MB'dan kucuk olmali.")
        if not raw:
            raise HTTPException(status_code=400, detail="Bos video dosyasi.")
        return await run_in_threadpool(process_video, raw, ext)
    finally:
        await file.close()


@app.get("/results/{result_id}.mp4")
def get_result(result_id: str):
    if not re.fullmatch(r"[a-f0-9]{32}", result_id):
        raise HTTPException(status_code=404, detail="Sonuc bulunamadi.")
    path = RESULTS / f"{result_id}.mp4"
    if not path.is_file():
        raise HTTPException(status_code=404, detail="Sonuc bulunamadi.")
    return FileResponse(path, media_type="video/mp4", filename="depth_result.mp4", content_disposition_type="inline")


@app.get("/video-depth-at/{result_id}")
def video_depth_at(
    result_id: str,
    frame: int = Query(ge=0),
    x: int = Query(ge=0),
    y: int = Query(ge=0),
):
    """Read one metric-depth prediction from the processed video frame."""
    if not re.fullmatch(r"[a-f0-9]{32}", result_id):
        raise HTTPException(status_code=404, detail="Video depth sonucu bulunamadi.")
    path = RESULTS / f"{result_id}_video.npy"
    if not path.is_file():
        raise HTTPException(status_code=404, detail="Video depth sonucu bulunamadi.")
    maps = np.load(path, mmap_mode="r", allow_pickle=False)
    frames, height, width = maps.shape
    if frame >= frames or x >= width or y >= height:
        raise HTTPException(status_code=422, detail="Kare veya piksel sinirlar disinda.")
    value = float(maps[frame, y, x])
    if not math.isfinite(value) or value <= 0:
        return {"frame": frame, "x": x, "y": y, "valid": False, "depth_m": None}
    return {
        "frame": frame, "x": x, "y": y,
        "valid": True, "depth_m": round(value, 4),
    }


# CANLI KAMERA ICIN AYRI ENDPOINT
# Kareler diske yazilmaz. Tek istekte RGB, depth PNG ve varsa secilen
# noktadaki metre tahmini beraber doner. Model cok hizli olmasa da
# kamera acildiginda otomatik analiz baslayabilir.
LIVE_MAX_BYTES = 6 * 1024 * 1024
LIVE_MAX_WIDTH = 640


def process_live_image(raw: bytes, u: float | None, v: float | None) -> dict:
    frame = cv2.imdecode(np.frombuffer(raw, dtype=np.uint8), cv2.IMREAD_COLOR)
    if frame is None:
        raise HTTPException(status_code=400, detail='Gecerli kamera JPEG goruntusu bulunamadi.')
    h, w = frame.shape[:2]
    if w > LIVE_MAX_WIDTH:
        new_h = max(1, int(round(h * LIVE_MAX_WIDTH / w)))
        frame = cv2.resize(frame, (LIVE_MAX_WIDTH, new_h), interpolation=cv2.INTER_AREA)
    h, w = frame.shape[:2]

    depth = np.asarray(
        model.predict(source=frame, imgsz=512, verbose=False)[0]
        .depth.data.cpu().numpy(), dtype=np.float32
    ).squeeze()
    if depth.ndim != 2:
        raise HTTPException(status_code=500, detail='Model 2 boyutlu derinlik haritasi dondurmedi.')
    if depth.shape != (h, w):
        depth = cv2.resize(depth, (w, h), interpolation=cv2.INTER_LINEAR)

    colored_bgr = colorize_depth(depth, cmap='spectral')
    ok_rgb, jpg = cv2.imencode('.jpg', frame, [int(cv2.IMWRITE_JPEG_QUALITY), 82])
    ok_depth, png = cv2.imencode('.png', colored_bgr)
    if not ok_rgb or not ok_depth:
        raise HTTPException(status_code=500, detail='Goruntu kodlanamadi.')

    response = {
        'width': w,
        'height': h,
        'rgb_jpg_b64': base64.b64encode(jpg).decode('ascii'),
        'depth_png_b64': base64.b64encode(png).decode('ascii'),
        'valid': False,
        'depth_m': None,
        'x': None,
        'y': None,
    }
    if u is not None and v is not None:
        x = min(w - 1, max(0, int(u * w)))
        y = min(h - 1, max(0, int(v * h)))
        distance = float(depth[y, x])
        response.update({
            'x': x,
            'y': y,
            'valid': math.isfinite(distance) and distance > 0,
            'depth_m': round(distance, 4)
                       if math.isfinite(distance) and distance > 0 else None,
        })
    return response


@app.post('/predict-live')
async def predict_live(
    file: UploadFile = File(...),
    u: float | None = Form(None),
    v: float | None = Form(None),
):
    try:
        if (u is None) != (v is None):
            raise HTTPException(status_code=422, detail='u ve v birlikte gonderilmelidir.')
        if u is not None and (not math.isfinite(u) or not 0 <= u <= 1 or
                              not math.isfinite(v) or not 0 <= v <= 1):
            raise HTTPException(status_code=422, detail='u ve v 0 ile 1 arasinda olmali.')
        raw = await file.read(LIVE_MAX_BYTES + 1)
        if not raw:
            raise HTTPException(status_code=400, detail='Kamera goruntusu bos.')
        if len(raw) > LIVE_MAX_BYTES:
            raise HTTPException(status_code=413, detail='Kamera karesi 6 MB sinirini asti.')
        return await run_in_threadpool(process_live_image, raw, u, v)
    finally:
        await file.close()


# GROUND TRUTH DEGERLENDIRME (DEPTH8): RGB + 16-BIT PNG
# Ayni dosya adina, ayni cozunurluge sahip goruntuler kabul edilir.
# Metrikler: SADECE GT ve model tahmini gecerli olan piksellerde hesaplanir.
GT_MAX_BYTES = 12 * 1024 * 1024


def _encode_color_png(values: np.ndarray, max_m: float, *, cmap: int,
                      valid: np.ndarray) -> str:
    """Use shared linear scale; masked pixels are black."""
    scaled = (np.clip(values, 0.0, max_m) / max_m * 255).astype(np.uint8)
    colored = cv2.applyColorMap(scaled, cmap)
    colored[~valid] = (0, 0, 0)
    ok, encoded = cv2.imencode('.png', colored)
    if not ok:
        raise HTTPException(status_code=500, detail='Karsilastirma goruntusu olusturulamadi.')
    return base64.b64encode(encoded.tobytes()).decode('ascii')


def run_gt_evaluation(rgb_bytes: bytes, gt_bytes: bytes,
                      rgb_filename: str, gt_filename: str) -> dict:
    if Path(rgb_filename).stem.lower() != Path(gt_filename).stem.lower():
        raise HTTPException(
            status_code=422,
            detail='RGB ve GT ayni isimli olmalidir (ornegin foto.jpg / foto.png).',
        )
    if Path(gt_filename).suffix.lower() != '.png':
        raise HTTPException(status_code=415, detail='GT dosyasi PNG olmali.')
    image = cv2.imdecode(np.frombuffer(rgb_bytes, dtype=np.uint8), cv2.IMREAD_COLOR)
    if image is None:
        raise HTTPException(status_code=400, detail='RGB goruntusu okunamadi.')

    # Depth8 sensor GT dosyalari 16-bit grayscale PNG, mm cinsindendir.
    raw_gt = cv2.imdecode(np.frombuffer(gt_bytes, dtype=np.uint8),
                          cv2.IMREAD_UNCHANGED)
    if raw_gt is None or raw_gt.ndim != 2 or raw_gt.dtype != np.uint16:
        raise HTTPException(
            status_code=422,
            detail='GT 16-bit tek kanalli PNG olmali. '
                   'Renkli PNG veya 8-bit gorunume donusturulmus dosya kullanma.',
        )
    height, width = image.shape[:2]
    if raw_gt.shape != (height, width):
        raise HTTPException(
            status_code=422,
            detail=f'Boyutlar farkli: RGB={width}x{height}, '
                   f'GT={raw_gt.shape[1]}x{raw_gt.shape[0]}. '
                   'Goruntuleri yeniden olceklendirme, eslesen orijinal dosyalari kullan.',
        )

    ground_truth = raw_gt.astype(np.float32) / 1000.0
    valid_gt = np.isfinite(ground_truth) & (ground_truth > 0)
    if not np.any(valid_gt):
        raise HTTPException(status_code=422, detail='GT dosyasinda pozitif derinlik yok.')

    result = model.predict(source=image, imgsz=768, verbose=False)[0]
    predicted = np.asarray(result.depth.data.cpu().numpy(), dtype=np.float32).squeeze()
    if predicted.ndim != 2:
        raise HTTPException(status_code=500, detail='YOLO 2 boyutlu depth donmedi.')
    if predicted.shape != (height, width):
        predicted = cv2.resize(predicted, (width, height), interpolation=cv2.INTER_LINEAR)

    valid_pred = np.isfinite(predicted) & (predicted > 0)
    common = valid_gt & valid_pred
    evaluated_pixels = int(np.count_nonzero(common))
    valid_gt_count = int(np.count_nonzero(valid_gt))
    if evaluated_pixels == 0:
        raise HTTPException(status_code=422,
                            detail='GT ile eslesen pozitif model tahmini bulunamadi.')
    gt = ground_truth[common].astype(np.float64)
    pred = predicted[common].astype(np.float64)
    error = np.abs(pred - gt)
    mae = float(np.mean(error))
    rmse = float(np.sqrt(np.mean((pred - gt) ** 2)))
    absrel = float(np.mean(error / gt))
    ratio = np.maximum(gt / pred, pred / gt)
    delta1_percent = float(np.mean(ratio < 1.25) * 100.0)

    # GT ve tahmin ayni colormap / 0..max araliginda gosterilir.
    # P99 uzeri gorunur renk icin doyurulur; sayisal metrikler KIRPILMAZ.
    upper_gt = float(np.percentile(ground_truth[valid_gt], 99))
    upper_pred = float(np.percentile(predicted[valid_pred], 99)) if np.any(valid_pred) else 0.0
    display_max = max(4.0, float(math.ceil(max(upper_gt, upper_pred))))
    display_max = min(display_max, 50000.0)
    error_map = np.abs(predicted - ground_truth)
    safe_error_map = np.where(common, error_map, 0.0)
    error_display_max = max(0.25, float(np.percentile(error, 95)))

    evaluation_id = uuid4().hex
    np.savez_compressed(
        RESULTS / f'{evaluation_id}_evaluation.npz',
        predicted=predicted,
        ground_truth=ground_truth,
    )
    return {
        'status': 'ok',
        'evaluation_id': evaluation_id,
        'width': width,
        'height': height,
        'gt_scale': 'uint16_png / 1000 = meter',
        'mae_m': round(mae, 5),
        'rmse_m': round(rmse, 5),
        'absrel': round(absrel, 6),
        'delta1': round(delta1_percent, 4),
        'gt_valid_percent': round(valid_gt_count / (width * height) * 100, 4),
        'evaluated_gt_percent': round(evaluated_pixels / valid_gt_count * 100, 4),
        'invalid_prediction_percent': round(
            (valid_gt_count - evaluated_pixels) / valid_gt_count * 100, 4
        ),
        'evaluated_pixels': evaluated_pixels,
        'display_max_m': display_max,
        'error_display_max_m': round(error_display_max, 4),
        'prediction_png_b64': _encode_color_png(
            predicted, display_max, cmap=cv2.COLORMAP_TURBO, valid=valid_pred
        ),
        'ground_truth_png_b64': _encode_color_png(
            ground_truth, display_max, cmap=cv2.COLORMAP_TURBO, valid=valid_gt
        ),
        'error_png_b64': _encode_color_png(
            safe_error_map, error_display_max,
            cmap=cv2.COLORMAP_INFERNO, valid=common,
        ),
    }


@app.post('/evaluate-depth')
async def evaluate_depth(
    rgb: UploadFile = File(...),
    ground_truth: UploadFile = File(...),
):
    try:
        rgb_raw = await rgb.read(GT_MAX_BYTES + 1)
        gt_raw = await ground_truth.read(GT_MAX_BYTES + 1)
        if not rgb_raw or not gt_raw:
            raise HTTPException(status_code=400, detail='RGB ve GT dosyalari bos olamaz.')
        if len(rgb_raw) > GT_MAX_BYTES or len(gt_raw) > GT_MAX_BYTES:
            raise HTTPException(status_code=413, detail='Dosyalar en fazla 12 MB olmali.')
        return await run_in_threadpool(
            run_gt_evaluation, rgb_raw, gt_raw,
            rgb.filename or '', ground_truth.filename or '',
        )
    finally:
        await rgb.close()
        await ground_truth.close()


@app.get('/evaluation-at/{evaluation_id}')
def evaluation_at(evaluation_id: str, x: int = Query(ge=0), y: int = Query(ge=0)):
    if not re.fullmatch(r'[a-f0-9]{32}', evaluation_id):
        raise HTTPException(status_code=404, detail='GT degerlendirme bulunamadi.')
    path = RESULTS / f'{evaluation_id}_evaluation.npz'
    if not path.is_file():
        raise HTTPException(status_code=404, detail='GT degerlendirme bulunamadi.')
    with np.load(path, allow_pickle=False) as data:
        predicted = data['predicted']
        ground_truth = data['ground_truth']
    height, width = ground_truth.shape
    if x >= width or y >= height:
        raise HTTPException(status_code=422, detail='Piksel sinirlar disinda.')
    p = float(predicted[y, x])
    g = float(ground_truth[y, x])
    valid = math.isfinite(p) and p > 0 and math.isfinite(g) and g > 0
    return {
        'x': x,
        'y': y,
        'valid': valid,
        'pred_m': round(p, 4) if math.isfinite(p) and p > 0 else None,
        'gt_m': round(g, 4) if math.isfinite(g) and g > 0 else None,
        'abs_error_m': round(abs(p-g), 4) if valid else None,
    }
