# SDD-03 — Pipeline de Renderização

**Versão:** 2.0 | **Status:** Implementado e validado | **Atualizado:** 2026-06-07

---

## 1. Visão geral

O pipeline de renderização executa dentro do processo XPC a cada frame solicitado pelo FCP. É composto de 4 fases sequenciais definidas pelo protocolo `FxTileableEffect` mais um pipeline interno de GPU em 3 fases.

```
FCP chama →  pluginState()
             destinationImageRect()
             sourceTileRect()
             renderDestinationImage()
                  │
                  └── TileProcessor.process()
                           ├── Fase A: extractAllTiles()
                           ├── Fase B: engine.upscaleBatch()
                           └── Fase C: gpuReconstruct()
```

---

## 2. Fase FxPlug: pluginState()

**Propósito:** Empacotar o estado dos parâmetros do Inspector em um payload mínimo para atravessar a fronteira XPC.

**Implementação:**
```swift
struct StateData {
    var scaleFactor: Int32   // 0 = 2×, 1 = 4×
    var engineMode:  Int32   // 0 = AI (CoreML), 1 = Fast (MPS)
}
```

O `StateData` (~8 bytes) é serializado como `NSData` e repassado para `renderDestinationImage()`. Qualquer processamento pesado aqui bloqueia a thread principal do FCP e causa o "beachball".

---

## 3. Fase FxPlug: destinationImageRect()

**Propósito:** Informar ao FCP as dimensões do buffer de saída que ele deve alocar.

**Implementação:** Retorna `sourceRect * scaleFactor`. Para 1920×1080 com 2×, retorna 3840×2160. O FCP aloca o buffer de destino antes de chamar `renderDestinationImage()`.

**Nota:** `FxRect` usa campos `Int32`, não `Double`.

---

## 4. Fase FxPlug: sourceTileRect()

**Propósito:** Informar ao FCP qual região da imagem fonte é necessária para renderizar um dado tile de destino.

**Implementação atual:** Retorna `imagePixelBounds` completo (frame inteiro). O particionamento em tiles é gerenciado internamente pelo `TileProcessor`, não negociado com o host. Isso simplifica a implementação ao custo de sempre receber o frame completo — adequado para o escopo atual.

**Alternativa futura:** Para frames 4K+, negociar tiles reais com o FCP reduziria o tráfego XPC. Requer implementar a matemática inversa de transformação de coordenadas.

---

## 5. Fase FxPlug: renderDestinationImage()

Coração do pipeline. Executado na render thread do FCP (pode haver múltiplas concorrentes durante export).

```swift
func renderDestinationImage(...) throws {
    // 1. Obter device + commandQueue do MetalDeviceCache
    // 2. Obter MTLTexture da fonte via FxImageTile.metalTexture(for:)
    // 3. Resolver engine (CoreML ou MPS) — lazy init + warmup
    // 4. Reutilizar TileProcessor (hoisted — não criar por frame)
    // 5. TileProcessor.process() → resultado upscalado
    // 6. Blit resultado → destTexture
    // 7. commandBuffer.commit() + waitUntilCompleted()
    // 8. Atualizar Status no Inspector via FxParameterSettingAPI_v5
}
```

**Thread safety:** `engines` e `processors` são protegidos por `NSLock`. `TileProcessor` é reutilizado entre frames (hoisted), não criado por frame.

---

## 6. Pipeline interno: TileProcessor

### Fase A — extractAllTiles()

Divide o frame de entrada em tiles de 512×512 com 16px de overlap. Todos os blits são encodados em **um único command buffer** (um commit/wait total).

```
Frame 1920×1080  →  4 colunas × 3 linhas = 12 tiles
                     Cada tile: 512×512 (interior) + 16px overlap por lado
                     Tile de borda: menor, sem overlap na borda externa
```

O overlap é necessário para que o modelo de IA tenha contexto nas bordas de cada tile, evitando artefatos de "seam" na reconstrução.

### Fase B — engine.upscaleBatch()

Envia todos os tiles para o engine selecionado. O engine retorna uma lista de texturas upscaladas.

**Caminho CoreML (AI):**
1. Para tiles não-512×512 (bordas do frame): `mpsResize()` redimensiona para exatamente 512×512 antes da inferência.
2. `batchConvert()`: encode BGRA→float16 para todos os tiles em um command buffer (Metal GPU).
3. `wrapAsMLMultiArray()`: zero-copy — o `MTLBuffer.storageModeShared` é exposto diretamente como `MLMultiArray` sem cópia.
4. Predições CoreML sequenciais com `outputBackings` pré-alocados (ANE escreve direto no buffer de saída).
5. `batchConvert()`: encode float16→BGRA para todos os tiles em um command buffer.
6. Para tiles de borda: `mpsResize()` volta para as dimensões `inputW*scale × inputH*scale`.

**Caminho MPS (Fast):** `MPSImageLanczosScale` + passe de sharpening. Latência: 3–148ms dependendo da resolução.

**Fallback automático:** Se CoreML falhar no warmup ou durante inferência, o sistema cai automaticamente para MPS e atualiza o Status no Inspector para "⚠ AI unavailable – using Fast".

### Fase C — gpuReconstruct()

Reconstrói o frame completo a partir dos tiles upscalados usando **feather blending** para eliminar costuras.

**Algoritmo:**
```
1. Alocar accumColor (rgba32Float, .private) e accumWeight (r32Float, .private)
2. Limpar via render passes vazios (zero)
3. Para cada tile:
   - tile_accumulate kernel: weighted accumulation com featherWeight()
   - featherWeight = fade linear de 1/(overlap+1) na borda → 1 no interior
4. tile_normalize kernel: accumColor / accumWeight → textura final
```

O peso `featherWeight` é o produto dos pesos horizontal e vertical, formando um filtro tent 2D. Tiles de canto estão em duas zonas de overlap simultaneamente — o produto `wx * wy` lida com isso corretamente.

**Fallback:** Se os Metal pipelines não estiverem disponíveis (`pipelineAccumulate` ou `pipelineNormalize` nil), usa `blitStitch()` — cópia hard sem blend. Produz costuras visíveis mas não falha.

---

## 7. Diferenciação preview vs render final (pendente)

O parâmetro `quality` em `pluginState(at:quality:)` indica se o FCP está em modo draft (scrub) ou final (export). Hoje é ignorado — ambos usam o mesmo engine.

**Implementação planejada:**
```swift
// quality == 0 → draft/preview → forçar Motor Fast
// quality == 1 → final render  → usar engine selecionado pelo usuário
let effectiveEngine = quality == 0 ? .fast : state.engineMode
```

Isso permitirá scrub fluido na timeline (MPS a 3–148ms/frame) e qualidade AI no render final, sem exigir que o editor mude o Inspector manualmente.

---

## 8. Diagrama de latência por fase (1080p 2×, M4 Pro)

| Fase | Tempo aproximado |
|---|---|
| extractAllTiles (6 tiles, 1 CB) | ~2ms |
| upscaleBatch CoreML (6 tiles sequenciais) | ~2.050ms |
| upscaleBatch MPS (6 tiles) | ~6ms |
| gpuReconstruct (feather blend) | ~3ms |
| **Total AI** | **~2.057ms** |
| **Total Fast** | **~9ms** |
