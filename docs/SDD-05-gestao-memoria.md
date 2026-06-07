# SDD-05 — Gestão de Memória e GPU

**Versão:** 2.0 | **Status:** Implementado e validado | **Atualizado:** 2026-06-07

---

## 1. Princípio central: zero-copy na memória unificada

No Apple Silicon, CPU, GPU e ANE compartilham o mesmo pool de memória física (UMA — Unified Memory Architecture). Um `MTLBuffer` com `storageMode = .shared` é acessível simultaneamente por todos os três sem cópia de dados.

O pipeline explora isso ao fazer `wrapAsMLMultiArray()` — o `MLMultiArray` aponta para o mesmo endereço físico do `MTLBuffer`. O ANE lê e escreve diretamente nessa memória. Nenhuma cópia CPU↔GPU ocorre no caminho quente.

---

## 2. Fluxo de memória por frame

```
FxImageTile
  └── MTLTexture (via IOSurface — compartilhado entre FCP e XPC sem cópia)
        │
        ▼  [extractAllTiles — 1 blit CB]
  MTLTexture[] (tiles, .shared, bgra8Unorm)
        │
        ▼  [bgra_to_planar_f16 — Metal compute]
  MTLBuffer[] (tiles, .shared, float16, layout [1,3,H,W])
        │
        ▼  [wrapAsMLMultiArray — zero-copy]
  MLMultiArray[] (mesmo endereço físico dos MTLBuffers de entrada)
        │
        ▼  [model.prediction() com outputBackings]
  MLMultiArray[] (output — mesmo endereço físico dos MTLBuffers de saída)
        │
        ▼  [wrapAsMLMultiArray inverso — zero-copy]
  MTLBuffer[] (saída, .shared, float16, layout [1,3,H*s,W*s])
        │
        ▼  [planar_f16_to_bgra — Metal compute]
  MTLTexture[] (tiles upscalados, .shared, bgra8Unorm)
        │
        ▼  [gpuReconstruct — feather blend]
  MTLTexture (frame completo, .shared, bgra8Unorm)
        │
        ▼  [blit → destTexture]
  FxImageTile (destino — devolvido ao FCP)
```

---

## 3. Alocação por tile

Para cada tile de 512×512 com fator de escala S:

| Buffer | Tamanho | Modo |
|---|---|---|
| Tile de entrada (BGRA) | 512×512×4 bytes = 1 MB | .shared |
| Buffer float16 entrada | 512×512×3×2 bytes = 1,5 MB | .shared |
| Buffer float16 saída | (512S)×(512S)×3×2 bytes | .shared |
| Tile de saída (BGRA) | (512S)×(512S)×4 bytes | .shared |

Para S=2: saída = 1024×1024, total ~8 MB por tile.
Para S=4: saída = 2048×2048, total ~30 MB por tile.

**Frame 1080p 2×:** 12 tiles × ~8 MB = ~96 MB de pico durante o batch.

---

## 4. wrapAsMLMultiArray — implementação zero-copy

```swift
func wrapAsMLMultiArray(_ buffer: MTLBuffer, width: Int, height: Int) throws -> MLMultiArray {
    // Monta MLMultiArray apontando para o storage do MTLBuffer (sem cópia)
    // Layout: [1, 3, height, width] — planar RGB, channel-first
    let shape: [NSNumber] = [1, 3, height as NSNumber, width as NSNumber]
    let strides: [NSNumber] = [
        NSNumber(value: 3 * height * width),
        NSNumber(value: height * width),
        NSNumber(value: width),
        1
    ]
    return try MLMultiArray(
        dataPointer: buffer.contents(),
        shape: shape,
        dataType: .float16,
        strides: strides,
        deallocator: nil  // MTLBuffer gerencia seu próprio lifetime
    )
}
```

**Por que `deallocator: nil`:** O `MTLBuffer` vive no escopo de `upscaleBatch()` e é retido pela closure enquanto o `MLMultiArray` existe. O CoreML não deve desalocar o buffer — ele pertence ao Metal.

---

## 5. Conversão de formato: Metal compute shaders

A conversão BGRA interleaved ↔ RGB planar float16 é feita por compute shaders em `TileUpscaler.metal`.

### bgra_to_planar_f16

```metal
kernel void bgra_to_planar_f16(
    texture2d<half, access::read> src [[texture(0)]],
    device half* dst                   [[buffer(0)]],
    constant ConvertParams& p          [[buffer(1)]],
    uint2 gid                          [[thread_position_in_grid]])
{
    if (gid.x >= p.width || gid.y >= p.height) return;
    // Metal expõe bgra8Unorm como RGBA no shader: .x=R, .y=G, .z=B, .w=A
    half4 px = src.read(gid);
    uint idx = gid.y * p.width + gid.x;
    // Planar: canal R primeiro, depois G, depois B
    dst[0 * p.width * p.height + idx] = px.x;  // R
    dst[1 * p.width * p.height + idx] = px.y;  // G
    dst[2 * p.width * p.height + idx] = px.z;  // B
}
```

**Nota de canal:** Textures `bgra8Unorm` são lidas pelo shader como RGBA (não BGRA). O Metal normaliza a ordem de leitura. Isso é correto e o modelo RealESRGAN espera RGB nessa ordem.

### planar_f16_to_bgra

Inverso do anterior: lê [1,3,H,W] planar float16, escreve `bgra8Unorm` com clamp para [0,1].

---

## 6. Texturas de acumulação — gpuReconstruct

As texturas de acumulação são alocadas em `.storageMode = .private` (GPU only) porque nenhum código CPU precisa lê-las durante o processamento:

| Textura | Formato | Uso |
|---|---|---|
| `accumColor` | rgba32Float, .private | Soma ponderada de RGBA por pixel |
| `accumWeight` | r32Float, .private | Soma dos pesos por pixel |

Limpas via render passes vazios (`loadAction = .clear`) — confiável em todos os chips Apple Silicon.

A normalização final (`accumColor / max(accumWeight, 1e-6)`) acontece no shader `tile_normalize`, escrevendo para a textura de saída `.shared`.

---

## 7. TileProcessor — ciclo de vida

**Antes (problemático):** `TileProcessor` era criado a cada frame em `renderDestinationImage()`. Isso recompilava pipeline states Metal e criava um novo command queue por frame.

**Atual (corrigido):** `TileProcessor` é criado uma vez por `deviceRegistryID` e reutilizado entre frames:

```swift
// Em UpscalerEffect:
private var processors: [UInt64: TileProcessor] = [:]
private let stateLock = NSLock()

// Em renderDestinationImage():
let processor: TileProcessor = stateLock.withLock {
    if let p = processors[sourceImage.deviceRegistryID] { return p }
    let p = TileProcessor(device: device)
    processors[sourceImage.deviceRegistryID] = p
    return p
}
```

Isso evita esgotamento do limite de 64 command queues por device (crítico em export com múltiplas render threads simultâneas).

---

## 8. autoreleasepool no caminho quente

`renderDestinationImage()` cria objetos Objective-C (via CoreML e Metal frameworks) que vão para o autorelease pool. A render thread do FCP não tem um runloop com pool automático — os objetos acumulam até o próximo flush do pool, causando picos de memória.

**Solução:** O corpo de `renderDestinationImage()` é envolvido em `autoreleasepool { }`:

```swift
try autoreleasepool {
    // ... todo o pipeline de render
}
```

---

## 9. Limites de memória e comportamento sob pressão

| Cenário | Comportamento |
|---|---|
| `makeCommandQueue()` retorna nil | Lança `UpscalerError.metalDeviceUnavailable` — FCP recebe erro, frame fica preto |
| `makeTexture()` retorna nil | Mesmo caminho — lança erro |
| CoreML falha durante inferência | Fallback para MPS, Status atualizado para "⚠ AI unavailable" |
| XPC encerrado pelo Jetsam (RAM esgotada) | FCP continua. Na próxima requisição, XPC é relançado pelo sistema |

O limite de memória do XPC depende do hardware. Em M1 16GB, o pico de ~96MB por frame (1080p 2×) é seguro. Em 4K 4×, o pico chega a ~1.5GB — crítico em M1 com 8GB.
