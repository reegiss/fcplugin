# SDD-04 — Motor de IA

**Versão:** 2.0 | **Status:** Implementado e validado | **Atualizado:** 2026-06-07

---

## 1. Escolha de tecnologia: CoreML vs MetalFX

O plugin oferece dois motores. A escolha entre eles é do editor via parâmetro Engine no Inspector.

| Critério | CoreML / RealESRGAN (AI) | MPS / Lanczos (Fast) |
|---|---|---|
| Qualidade | Alta — reconstrói texturas e detalhes | Média — suaviza sem adicionar detalhes |
| Latência 1080p 2× (M4 Pro) | ~2.057ms | ~9ms |
| Latência 4K 4× (M4 Pro) | ~29.751ms | ~148ms |
| Tempo real? | Nunca | Quase (4K 4× ≈ 7fps) |
| Uso de ANE | Sim | Não |

**Decisão arquitetural:** CoreML para render final, MPS para preview. O editor não deveria precisar escolher manualmente — a diferenciação automática via parâmetro `quality` está pendente (ver SDD-03 Seção 7).

**MetalFX foi descartado** apesar de ser mais rápido que MPS (~8–15ms para 4K). Razão: qualidade insuficiente para entrega profissional. MetalFX é adequado para jogos, não para pós-produção.

---

## 2. Modelos e conversão

### Arquitetura RealESRGAN

- **RealESRGAN x2plus:** pixel_unshuffle(2) → RRDB backbone → saída 2× nativa
- **RealESRGAN x4plus:** RRDB backbone → saída 4× nativa

Ambos treinados em PyTorch. Convertidos para CoreML via `scripts/convert_realesrgan.py` + `xcrun coremlc compile`.

### Shapes fixos — obrigatório para ANE

O ANE requer shapes de tensor **estaticamente definidos** em tempo de compilação do modelo. Shapes flexíveis forçam fallback para GPU ou CPU, multiplicando a latência.

**Configuração usada:**
```python
# Durante conversão com coremltools
input_shape = ct.Shape(shape=(1, 3, 512, 512))  # fixo, não flexível
```

A entrada é sempre exatamente **512×512 pixels** (3 canais, float32, valores em [0, 1]). Tiles que diferem dessas dimensões (bordas do frame) são redimensionados via MPS antes da inferência — ver Seção 4.

### Formato de entrada/saída do modelo

```
Entrada:  [1, 3, 512, 512]  float32  — planar RGB, valores 0.0–1.0
Saída:    [1, 3, W, H]      float32  — planar RGB, valores 0.0–1.0
          onde W = 512*scale, H = 512*scale
```

O modelo trabalha em RGB planar. O formato nativo do Metal é BGRA interleaved. A conversão é feita via Metal compute shaders (`bgra_to_planar_f16` e `planar_f16_to_bgra`) — ver SDD-05.

---

## 3. Pipeline de inferência zero-copy

A premissa central é que no Apple Silicon, CPU, GPU e ANE compartilham a mesma memória física. Uma textura `MTLTexture` e um `MLMultiArray` podem apontar para o mesmo endereço físico sem cópia.

### Caminho implementado (MTLBuffer + wrapAsMLMultiArray)

```
MTLTexture (BGRA, .shared)
    │
    ▼ [Metal compute: bgra_to_planar_f16]
MTLBuffer (.storageModeShared, float16)
    │
    ▼ [wrapAsMLMultiArray — zero-copy: mesmo endereço físico]
MLMultiArray (float16, shape [1,3,512,512])
    │
    ▼ [model.prediction() com outputBackings pré-alocado]
MLMultiArray (float16, shape [1,3,W,H])  ← ANE escreve direto aqui
    │
    ▼ [wrapAsMLMultiArray — zero-copy inverso]
MTLBuffer (.storageModeShared, float16)
    │
    ▼ [Metal compute: planar_f16_to_bgra]
MTLTexture (BGRA, .shared)
```

**Ponto crítico em `outputBackings`:**
```swift
// CORRETO:
var opts = MLPredictionOptions()
opts.outputBackings = ["output": outputArray]  // MLMultiArray direto

// ERRADO (causa exceção em runtime):
opts.outputBackings = ["output": MLFeatureValue(multiArray: outputArray)]
```

### Otimização batch

Para N tiles, o pipeline executa:
1. **1 command buffer Metal**: BGRA→float16 para todos os N tiles
2. **N predições CoreML sequenciais** (cada uma escreve no output backing pré-alocado)
3. **1 command buffer Metal**: float16→BGRA para todos os N tiles

Total de commits GPU: **2** (independente de N). A versão anterior fazia N×2 commits.

---

## 4. Tratamento de tiles não-512×512

Tiles nas bordas do frame têm dimensões menores que 512×512 (e.g., o tile da borda direita de um frame 1920px de largura: 1920 - 3×512 = 384px de largura).

**Solução implementada:** `mpsResize()` — redimensionamento Lanczos via MPS para 512×512 antes da inferência, e de volta para `inputW*scale × inputH*scale` após.

```swift
let resizedInputs = try inputs.map { tex in
    if tex.width == 512 && tex.height == 512 { return tex }
    return try mpsResize(tex, toWidth: 512, height: 512)
}
```

**Tradeoff:** O redimensionamento introduz uma leve degradação nos pixels de borda (double interpolation: Lanczos down → AI up → Lanczos up). Em frames com muitos tiles de borda (resoluções pequenas ou muito grandes), esse efeito pode ser perceptível em comparação ideal. Na prática, a alternativa (falhar e cair para MPS para o frame inteiro) é pior.

**Melhoria futura:** Tiles de borda poderiam ser processados por um modelo com shapes enumerados adicionais (e.g., 384×512, 512×384) — eliminando o mpsResize extra.

---

## 5. Warmup e caching dos motores

O carregamento do modelo CoreML (`MLModel.load()`) é assíncrono e lento (~500ms–2s). É feito uma vez, na primeira vez que o engine é requisitado, e cacheado.

```swift
// Lazy init + warmup na primeira chamada
private var engines: [String: any UpscalerEngine] = [:]
private let stateLock = NSLock()

func resolvedEngine(scale:, engineMode:, device:) throws -> any UpscalerEngine {
    let key = "\(engineMode)-\(scale.rawValue)"
    if let cached = stateLock.withLock({ engines[key] }) { return cached }
    // ... warmup async via DispatchSemaphore
    stateLock.withLock { engines[key] = engine }
}
```

**Motores disponíveis:** até 4 instâncias simultâneas (2× AI, 4× AI, 2× Fast, 4× Fast). Cada instância carrega seu próprio modelo. Pico de memória quando todos estão carregados: ~66MB de modelos + buffers de tile.

---

## 6. Qualidade visual observada

Teste com foto real (iPhone, 3918×2470 reduzida para 480×302, upscalada 4×):

| Motor | Características visuais |
|---|---|
| Lanczos (MPS) | Imagem suave. Bordas levemente desfocadas. Sem detalhes novos. |
| RealESRGAN (AI) | Texturas reconstruídas. Bordas nítidas. Ruído suprimido. Detalhes sintéticos plausíveis. |

A diferença é mais pronunciada em:
- Texturas repetitivas (tecido, grama, cabelo, madeira)
- Bordas de alto contraste
- Texto e elementos gráficos
- Imagens com ruído (ISO alto, compressão JPEG pesada)

---

## 7. Compute units em testes vs produção

| Contexto | Configuração | Motivo |
|---|---|---|
| Testes automatizados | `.cpuAndGPU` | ANE causa crashes no processo sandboxed de testes |
| Produção (XPC service) | `.all` (ANE + GPU + CPU) | ANE disponível e necessário para performance |
