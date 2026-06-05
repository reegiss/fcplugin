# FCP AI Upscaler Plugin — Design Spec

**Data:** 2026-06-05
**Status:** Aprovado

---

## 1. Objetivo

Plugin para Final Cut Pro e Motion que aplica upscaling de vídeo com IA diretamente no timeline, funcionando tanto em preview em tempo real quanto em export. Processamento 100% on-device, sem chamadas de rede. Suporta fatores 2x e 4x. Hardware target: Apple Silicon M1+.

---

## 2. Arquitetura Geral

O plugin é um bundle `.fxplug` (processo XPC separado do FCP) com três camadas:

```
┌─────────────────────────────────────────────────┐
│  FxPlug Layer                                   │
│  UpscalerEffect : FxTileableEffect              │
│  - declara parâmetros (fator, modo de qualidade)│
│  - recebe frames do FCP, delega ao Engine Layer │
└────────────────────┬────────────────────────────┘
                     │
┌────────────────────▼────────────────────────────┐
│  Engine Layer                                   │
│  UpscalerEngine (protocol)                      │
│  ├── MPSUpscaler    (preview rápido)            │
│  └── CoreMLUpscaler (qualidade máxima)          │
└────────────────────┬────────────────────────────┘
                     │
┌────────────────────▼────────────────────────────┐
│  Tiling Layer                                   │
│  TileProcessor                                  │
│  - divide frame em tiles com overlap            │
│  - processa cada tile via UpscalerEngine        │
│  - reconstrói frame com overlap blending        │
└─────────────────────────────────────────────────┘
```

**Fluxo de um frame:**
`CVPixelBuffer (FCP) → MTLTexture → TileProcessor → UpscalerEngine → MTLTexture → CVPixelBuffer (FCP)`

O `UpscalerEffect` mantém uma instância de cada engine pré-aquecida em memória. A troca de engine é instantânea — apenas muda qual instância o `TileProcessor` usa.

---

## 3. Bundle Structure

```
AIUpscaler.fxplug/
├── Contents/
│   ├── Info.plist
│   ├── MacOS/
│   │   └── AIUpscaler
│   └── Resources/
│       ├── realesrgan_2x.mlpackage
│       ├── realesrgan_4x.mlpackage
│       └── default.metallib
```

**Info.plist — campos críticos:**
- `FXPlug API Version`: 4
- `FXCategory`: `FxPlug`
- `FXPlugInAttributes`: suporte a tiles e threading

Os dois modelos `.mlpackage` são bundled com o plugin — sem download em runtime. Modelos separados por fator de escala para evitar lógica de reshape em runtime.

Caminhos de instalação do plugin (FCP descobre automaticamente):
- `~/Library/Plug-Ins/FxPlug/`
- `/Library/Plug-Ins/FxPlug/`

---

## 4. Parâmetros do Plugin

| Parâmetro | Tipo | Valores | Default |
|---|---|---|---|
| Scale Factor | Menu popup | 2x, 4x | 2x |
| Quality Mode | Menu popup | Fast, Best | Fast |

**Fast** → MPSUpscaler. **Best** → CoreMLUpscaler.

Troca de Scale Factor recarrega o modelo CoreML (~1s). Troca de Quality Mode é instantânea.

### Backlog de parâmetros futuros (não implementar agora)
- Sharpness / detail enhancement
- Noise reduction pre-processing
- Tile size override (para hardware mais potente)
- Face enhancement mode

---

## 5. UpscalerEngine Protocol

```swift
protocol UpscalerEngine {
    var scaleFactor: ScaleFactor { get }
    func upscale(input: MTLTexture, commandBuffer: MTLCommandBuffer) throws -> MTLTexture
    func warmup() async throws
}

enum ScaleFactor: Int {
    case x2 = 2
    case x4 = 4
}
```

### MPSUpscaler (Fast)

Usa `MPSImageLanczosScale` para o upscale base, seguido de uma passagem `MPSCNNConvolution` com pesos de sharpening compilados no `default.metallib` (Float16). Sem arquivo de modelo externo — pesos em memória ao inicializar.

- Latência esperada: < 16ms por tile em M1
- Adequado para preview em 60fps

### CoreMLUpscaler (Best)

Carrega `realesrgan_2x.mlpackage` ou `realesrgan_4x.mlpackage` via `MLModel(contentsOf:configuration:)`.

```swift
let config = MLModelConfiguration()
config.computeUnits = .all  // ANE + GPU + CPU
```

Modelo carregado uma vez em `warmup()`, mantido em memória. Aceita `CVPixelBuffer` diretamente, sem conversão intermediária.

- Latência esperada: 50–150ms por tile em M1
- Adequado para export; não usar para preview em tempo real

---

## 6. Tiling Pipeline

Modelos de super-resolução têm input de tamanho fixo. Frames grandes são divididos em tiles, processados individualmente e reconstituídos.

### Parâmetros

| Parâmetro | Valor | Motivo |
|---|---|---|
| Tile size (input) | 512×512 | Cabe no ANE e VRAM do M1 |
| Overlap | 16px | Elimina artefatos de borda |
| Max tiles paralelos | 1 | Modelos já paralelizam internamente via Metal |

### Overlap blending

Cada tile é processado com 16px extras em cada borda. Na reconstituição, as regiões de overlap usam alpha blending linear para fundir tiles adjacentes e eliminar descontinuidades visíveis.

```
overlap input (16px) → output (32px em 2x, 64px em 4x) → blended na reconstituição
```

Todo o pipeline opera em `MTLTexture` — nenhuma cópia para CPU durante o processamento. O `MTLCommandBuffer` é passado do FxPlug diretamente ao engine.

---

## 7. Error Handling

```swift
enum UpscalerError: Error {
    case modelLoadFailed(underlying: Error)
    case metalDeviceUnavailable
    case tileSizeMismatch(expected: CGSize, got: CGSize)
    case renderTimeout  // threshold: 5000ms por frame
}
```

| Cenário | Comportamento |
|---|---|
| Model load failed | Reporta `NSError` ao FCP; exibe frame original (passthrough) |
| Metal unavailable | Erro fatal; plugin não inicializa |
| Tile size mismatch | Log + skip do tile afetado; frame parcialmente processado |
| Render timeout | Passthrough no frame afetado; timeline não trava |

O passthrough garante que o editor nunca veja frame corrompido — no pior caso vê o vídeo original sem efeito.

---

## 8. Testing

| Tipo | Cobertura |
|---|---|
| Unit (Swift Testing) | `TileProcessor`: divisão e reconstituição com imagens sintéticas |
| Unit | `MPSUpscaler`: verifica dimensões de output (input × scaleFactor) |
| Unit | `CoreMLUpscaler`: smoke test de carregamento do modelo |
| Integration | Pipeline completo: frame 1920×1080 → 2x → verifica output 3840×2160 |
| Manual | Preview no FCP com clipe real; export de 10s em 4K |

Testes de unit usam frames sintéticos (gradientes, padrões geométricos) e não dependem do FCP instalado.

---

## 9. Dependências e Requisitos

- macOS 13+ (Ventura) — para FxPlug 4 e Core ML 7
- Final Cut Pro 10.6.5+
- Apple Silicon M1+ (sem suporte a Intel)
- Xcode 15+ para build
- FxPlug SDK (download do Apple Developer Portal)
- Modelo RealESRGAN pré-convertido para `.mlpackage` (conversão via `coremltools`)
