"""
Converts RealESRGAN x2plus and x4plus PyTorch weights to Core ML .mlpackage format.
Output: AIUpscaler/AIUpscaler/Resources/realesrgan_2x.mlpackage
        AIUpscaler/AIUpscaler/Resources/realesrgan_4x.mlpackage

Usage: python3.11 scripts/convert_realesrgan.py
Requirements: pip install coremltools torch torchvision
"""
import os
import urllib.request
import torch
import torch.nn as nn
import coremltools as ct

RESOURCES_DIR = "AIUpscaler/AIUpscaler/Resources"
MODELS = [
    {
        "name": "realesrgan_2x",
        # x2plus uses pixel_unshuffle(2) on input: 3ch → 12ch at half resolution,
        # then a scale=4 RRDBNet brings it back to 2× the original resolution.
        "num_in_ch": 12,
        "scale": 4,
        "pixel_unshuffle": 2,
        "url": "https://github.com/xinntao/Real-ESRGAN/releases/download/v0.2.1/RealESRGAN_x2plus.pth",
        "num_feat": 64,
        "num_block": 23,
    },
    {
        "name": "realesrgan_4x",
        "num_in_ch": 3,
        "scale": 4,
        "pixel_unshuffle": None,
        "url": "https://github.com/xinntao/Real-ESRGAN/releases/download/v0.1.0/RealESRGAN_x4plus.pth",
        "num_feat": 64,
        "num_block": 23,
    },
]


# ---------------------------------------------------------------------------
# Minimal RRDBNet (matches Real-ESRGAN pretrained weight keys exactly)
# ---------------------------------------------------------------------------

class ResidualDenseBlock(nn.Module):
    def __init__(self, num_feat=64, num_grow_ch=32):
        super().__init__()
        self.conv1 = nn.Conv2d(num_feat,               num_grow_ch, 3, 1, 1)
        self.conv2 = nn.Conv2d(num_feat + num_grow_ch,  num_grow_ch, 3, 1, 1)
        self.conv3 = nn.Conv2d(num_feat + 2*num_grow_ch, num_grow_ch, 3, 1, 1)
        self.conv4 = nn.Conv2d(num_feat + 3*num_grow_ch, num_grow_ch, 3, 1, 1)
        self.conv5 = nn.Conv2d(num_feat + 4*num_grow_ch, num_feat,   3, 1, 1)
        self.lrelu = nn.LeakyReLU(negative_slope=0.2, inplace=True)

    def forward(self, x):
        x1 = self.lrelu(self.conv1(x))
        x2 = self.lrelu(self.conv2(torch.cat((x, x1), 1)))
        x3 = self.lrelu(self.conv3(torch.cat((x, x1, x2), 1)))
        x4 = self.lrelu(self.conv4(torch.cat((x, x1, x2, x3), 1)))
        x5 = self.conv5(torch.cat((x, x1, x2, x3, x4), 1))
        return x5 * 0.2 + x


class RRDB(nn.Module):
    def __init__(self, num_feat, num_grow_ch=32):
        super().__init__()
        self.rdb1 = ResidualDenseBlock(num_feat, num_grow_ch)
        self.rdb2 = ResidualDenseBlock(num_feat, num_grow_ch)
        self.rdb3 = ResidualDenseBlock(num_feat, num_grow_ch)

    def forward(self, x):
        out = self.rdb1(x)
        out = self.rdb2(out)
        out = self.rdb3(out)
        return out * 0.2 + x


class RRDBNet(nn.Module):
    def __init__(self, num_in_ch, num_out_ch, scale, num_feat=64, num_block=23, num_grow_ch=32):
        super().__init__()
        self.scale = scale
        self.conv_first = nn.Conv2d(num_in_ch, num_feat, 3, 1, 1)
        self.body = nn.Sequential(*[RRDB(num_feat, num_grow_ch) for _ in range(num_block)])
        self.conv_body = nn.Conv2d(num_feat, num_feat, 3, 1, 1)
        self.conv_up1  = nn.Conv2d(num_feat, num_feat, 3, 1, 1)
        self.conv_up2  = nn.Conv2d(num_feat, num_feat, 3, 1, 1)  # present for both 2x and 4x
        self.conv_hr   = nn.Conv2d(num_feat, num_feat, 3, 1, 1)
        self.conv_last = nn.Conv2d(num_feat, num_out_ch, 3, 1, 1)
        self.lrelu = nn.LeakyReLU(negative_slope=0.2, inplace=True)

    def forward(self, x):
        feat = self.conv_first(x)
        body_feat = self.conv_body(self.body(feat))
        feat = feat + body_feat
        feat = self.lrelu(self.conv_up1(nn.functional.interpolate(feat, scale_factor=2, mode='nearest')))
        feat = self.lrelu(self.conv_up2(nn.functional.interpolate(feat, scale_factor=2, mode='nearest')))
        out = self.conv_last(self.lrelu(self.conv_hr(feat)))
        return out


class RealESRGAN2xWrapper(nn.Module):
    """Wraps RRDBNet for x2plus: applies pixel_unshuffle(2) before the network."""
    def __init__(self, rrdb: RRDBNet):
        super().__init__()
        self.rrdb = rrdb

    def forward(self, x):
        x = nn.functional.pixel_unshuffle(x, downscale_factor=2)
        return self.rrdb(x)


# ---------------------------------------------------------------------------
# Conversion
# ---------------------------------------------------------------------------

os.makedirs(RESOURCES_DIR, exist_ok=True)

for cfg in MODELS:
    weights_path = f"/tmp/{cfg['name']}.pth"
    if not os.path.exists(weights_path):
        print(f"Downloading {cfg['name']}...")
        urllib.request.urlretrieve(cfg["url"], weights_path)

    rrdb = RRDBNet(
        num_in_ch=cfg["num_in_ch"],
        num_out_ch=3,
        scale=cfg["scale"],
        num_feat=cfg["num_feat"],
        num_block=cfg["num_block"],
    )

    ckpt = torch.load(weights_path, map_location="cpu", weights_only=True)
    state_dict = ckpt.get("params_ema") or ckpt.get("params") or ckpt
    rrdb.load_state_dict(state_dict, strict=True)
    rrdb.eval()

    if cfg["pixel_unshuffle"]:
        model = RealESRGAN2xWrapper(rrdb)
        # Input to CoreML model is original 3-channel frame
        input_shape = (1, 3, 512, 512)
    else:
        model = rrdb
        input_shape = (1, 3, 512, 512)

    example_input = torch.zeros(*input_shape)
    with torch.no_grad():
        traced = torch.jit.trace(model, example_input)

    print(f"Converting {cfg['name']} to Core ML...")
    mlmodel = ct.convert(
        traced,
        inputs=[ct.TensorType(name="input", shape=input_shape)],
        outputs=[ct.TensorType(name="output")],
        compute_precision=ct.precision.FLOAT16,
        minimum_deployment_target=ct.target.macOS13,
    )

    out_path = os.path.join(RESOURCES_DIR, f"{cfg['name']}.mlpackage")
    mlmodel.save(out_path)
    print(f"Saved {out_path}")

print("Done.")
