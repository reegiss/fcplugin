"""
Converts RealESRGAN x2plus and x4plus PyTorch weights to Core ML .mlpackage format.
Output: AIUpscaler/AIUpscaler/Resources/realesrgan_2x.mlpackage
        AIUpscaler/AIUpscaler/Resources/realesrgan_4x.mlpackage

Usage: python scripts/convert_realesrgan.py
Requirements: pip install coremltools torch torchvision basicsr realesrgan
"""
import os
import urllib.request
import torch
import coremltools as ct
from basicsr.archs.rrdbnet_arch import RRDBNet
from realesrgan import RealESRGANer

RESOURCES_DIR = "AIUpscaler/AIUpscaler/Resources"
MODELS = [
    {
        "name": "realesrgan_2x",
        "scale": 2,
        "url": "https://github.com/xinntao/Real-ESRGAN/releases/download/v0.2.1/RealESRGAN_x2plus.pth",
        "num_feat": 64,
        "num_block": 23,
    },
    {
        "name": "realesrgan_4x",
        "scale": 4,
        "url": "https://github.com/xinntao/Real-ESRGAN/releases/download/v0.1.0/RealESRGAN_x4plus.pth",
        "num_feat": 64,
        "num_block": 23,
    },
]

os.makedirs(RESOURCES_DIR, exist_ok=True)

for cfg in MODELS:
    weights_path = f"/tmp/{cfg['name']}.pth"
    if not os.path.exists(weights_path):
        print(f"Downloading {cfg['name']}...")
        urllib.request.urlretrieve(cfg["url"], weights_path)

    model = RRDBNet(
        num_in_ch=3, num_out_ch=3,
        num_feat=cfg["num_feat"], num_block=cfg["num_block"],
        scale=cfg["scale"]
    )
    upsampler = RealESRGANer(
        scale=cfg["scale"], model_path=weights_path,
        model=model, tile=0, half=False
    )
    model.eval()

    # Trace with a representative tile (512×512, 3-channel, float32)
    example_input = torch.zeros(1, 3, 512, 512)
    traced = torch.jit.trace(model, example_input)

    mlmodel = ct.convert(
        traced,
        inputs=[ct.TensorType(name="input", shape=(1, 3, 512, 512))],
        outputs=[ct.TensorType(name="output")],
        compute_precision=ct.precision.FLOAT16,
        minimum_deployment_target=ct.target.macOS13,
    )

    out_path = os.path.join(RESOURCES_DIR, f"{cfg['name']}.mlpackage")
    mlmodel.save(out_path)
    print(f"Saved {out_path}")

print("Done.")
