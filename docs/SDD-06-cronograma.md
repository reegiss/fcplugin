# SDD-06 — Cronograma e Roadmap

**Versão:** 2.0 | **Status:** Fase 1–5 concluídas | **Atualizado:** 2026-06-07

---

## 1. Resumo executivo

O plugin está funcional em produção. As fases de fundação (arquitetura XPC, motor AI, pipeline GPU, gestão de memória, testes e benchmark) foram concluídas. As fases seguintes focam em experiência do editor e distribuição.

| Fase | Descrição | Status | Esforço real |
|---|---|---|---|
| 1 | CoreML pipeline + modelos | ✅ Concluída | ~40h |
| 2 | Arquitetura XPC + PlugInKit + signing | ✅ Concluída | ~35h |
| 3 | Pipeline GPU zero-copy + Metal shaders | ✅ Concluída | ~50h |
| 4 | TileProcessor + FxTileableEffect + testes | ✅ Concluída | ~60h |
| 5 | Inspector UI + Motion template | ✅ Concluída | ~20h |
| 6 | Preview vs render final | ⏳ Próxima | ~15h |
| 7 | Distribuição (PKG + notarização) | ⏳ Planejada | ~20h |
| 8 | Validação em M1/M2/M3 | ⏳ Planejada | ~15h |
| 9 | Otimização de borda (tiles não-512×512) | ⏳ Opcional | ~25h |

---

## 2. Fases concluídas — detalhamento

### Fase 1 — CoreML Pipeline (~40h)
- Download e conversão RealESRGAN x2plus e x4plus de PyTorch para CoreML
- Configuração de shapes fixos 512×512 (obrigatório para ANE)
- Validação da inferência no ANE via Instruments
- Implementação de `CoreMLUpscaler` com zero-copy `MTLBuffer + wrapAsMLMultiArray`
- Batch prediction com `outputBackings` pré-alocados
- **Bug encontrado e corrigido:** `outputBackings` exige `MLMultiArray` bruto, não `MLFeatureValue`

### Fase 2 — Arquitetura XPC (~35h)
- Estrutura do bundle: Wrapper App + XPC Service
- `Info.plist` com `PlugInKit` (não `NSExtension`) e `protocolNames = FxFilter`
- Signing com Developer ID real — ad-hoc causa crash DYLD no macOS 26
- `ENABLE_HARDENED_RUNTIME = YES`, `ENABLE_APP_SANDBOX = NO`
- Sequência de instalação: `lsregister` + lançar wrapper
- Motion template `.moef` para visibilidade no FCP

### Fase 3 — Pipeline GPU zero-copy (~50h)
- Metal shaders: `bgra_to_planar_f16`, `planar_f16_to_bgra`, `tile_accumulate`, `tile_normalize`
- Feather blending na reconstrução (sem costuras visíveis)
- Redução de commits GPU de N×2 para 2 por frame (batch)
- `mpsResize()` para tiles de borda não-512×512
- Benchmark CLI (`scripts/run_benchmark.sh + benchmark.swift`)

### Fase 4 — TileProcessor + Testes (~60h)
- `TileProcessor`: extração batch (1 CB), reconstrução GPU com feather blend
- 15 testes automatizados (6 suites) — todos passando
- Correções de produção: hoisting do TileProcessor, NSLock em `engines`, `autoreleasepool`
- Fix `internalQueue` force-unwrap → optional com fallback de erro

### Fase 5 — Inspector UI + Motion template (~20h)
- 3 parâmetros no FCP Inspector (Scale, Engine, Status)
- Motion template funcional com publicação de Scale e Engine
- Status dinâmico: "● AI Active" / "● Fast Active" / "⚠ AI unavailable – using Fast"

---

## 3. Roadmap — próximas fases

### Fase 6 — Diferenciação preview vs render final (prioridade alta, ~15h)

**Problema:** Hoje o motor AI é usado tanto em scrub quanto em export. O editor vê lentidão no timeline mesmo em preview.

**Implementação:**
```swift
// pluginState(at:quality:) — quality: 0=draft, 1=final
let effectiveEngine: Int32 = (quality == 0) ? 1 : state.engineMode
// quality 0 → forçar Motor Fast
// quality 1 → usar o motor escolhido pelo editor
```

**Entregáveis:**
- Modificar `pluginState()` para ler o parâmetro `quality`
- Passar `effectiveEngine` no `StateData`
- Testar comportamento de scrub vs export no FCP
- Documentar no Inspector (talvez adicionar label "Render mode: Auto")

### Fase 7 — Distribuição (PKG + notarização, ~20h)

**Problema:** O plugin só existe localmente. Não há instalador.

**Entregáveis:**
- PKG installer que copia o `.app` e o `.moef` para os lugares corretos
- Notarização via `notarytool` (Xcode CLI)
- DMG para distribuição
- Versionar o `.moef` no repositório
- Documentar processo completo em `docs/distribution.md`

Rascunho inicial já existe em `docs/distribution.md`.

### Fase 8 — Validação em M1/M2/M3 (~15h)

**Problema:** Todo o desenvolvimento e benchmark foi feito em M4 Pro. Performance e comportamento em chips mais antigos é desconhecida.

**Entregáveis:**
- Executar benchmark em M1 (16GB), M2 (16GB), M3 (18GB)
- Validar que ANE está sendo usado (Instruments → Core ML)
- Identificar se há fallbacks inesperados para CPU
- Ajustar limites de memória e tiles se necessário
- Documentar tabela de latência por chip

**Estimativa M1 base (extrapolada):** 1080p 4× → ~25s/frame (vs 8.9s no M4 Pro). Aceitável para render final; inaceitável para preview — reforça prioridade da Fase 6.

### Fase 9 — Otimização de tiles de borda (opcional, ~25h)

**Problema:** Tiles de borda (não-512×512) passam por dois redimensionamentos Lanczos (entrada e saída), reduzindo a qualidade AI nessas regiões.

**Solução:** Adicionar shapes enumerados adicionais ao modelo CoreML:

```python
# Durante conversão:
enumerated_shapes = ct.EnumeratedShapes(shapes=[
    ct.Shape(shape=(1, 3, 512, 512)),
    ct.Shape(shape=(1, 3, 512, 384)),  # borda direita para 1920px
    ct.Shape(shape=(1, 3, 384, 512)),  # borda inferior para 1080px
    ct.Shape(shape=(1, 3, 384, 384)),  # canto
])
```

**Tradeoff:** Aumenta o tamanho do `.mlmodelc` e tempo de compilação. Pode invalidar otimização ANE se os shapes adicionais não couberem no mesmo kernel compilado.

---

## 4. Débitos técnicos conhecidos

| Item | Impacto | Esforço | Prioridade |
|---|---|---|---|
| Motion template fora do git | Instalação manual obrigatória | Baixo | Alta |
| Modelos fora do git | Onboarding difícil | Baixo | Média |
| Status do Inspector via render thread | Best-effort (pode atrasar) | Médio | Baixa |
| Validação 8GB RAM (M1/M2 base) | Possível OOM em 4K 4× | Alto | Alta |

---

## 5. Estimativa de esforço total

| Categoria | Horas |
|---|---|
| Fases 1–5 concluídas | ~205h |
| Fases 6–8 planejadas | ~50h |
| Fase 9 opcional | ~25h |
| **Total estimado do projeto completo** | **~280h** |

Dentro da estimativa original de 280–350h. A margem superior foi consumida parcialmente pelo debugging de sandboxing/signing e pela descoberta do bug `outputBackings`.
