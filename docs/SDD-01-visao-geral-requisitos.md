# SDD-01 — Visão Geral e Requisitos

**Versão:** 2.0 | **Status:** Implementado e validado em produção | **Atualizado:** 2026-06-07

---

## 1. Objetivo

Plugin nativo para **Final Cut Pro** e **Motion** que realiza upscaling de vídeo via IA diretamente no dispositivo, sem dependência de rede. Integrado à interface do FCP como efeito aplicável na timeline.

**Restrições de escopo (v1):**
- Somente Apple Silicon (M1+). Intel não é suportado e não será.
- Inferência local apenas. Zero cloud.
- Upscaling estático por frame (sem super-resolução temporal multi-frame).
- Qualidade de render final — não realtime. O motor Fast (MPS/Lanczos) cobre o preview.

---

## 2. Estado atual do projeto

O plugin está **funcional em produção** no Final Cut Pro Creator Studio 12.2 no macOS 26 (Tahoe). O pipeline completo foi validado end-to-end.

| Componente | Status |
|---|---|
| Estrutura XPC + PlugInKit | ✅ Operacional |
| Motor AI (CoreML/RealESRGAN 2× e 4×) | ✅ Operacional |
| Motor Fast (MPS/Lanczos) | ✅ Operacional |
| TileProcessor com GPU blend (feather) | ✅ Operacional |
| Pipeline zero-copy MTLBuffer → ANE | ✅ Operacional |
| Motion template (visibilidade no FCP) | ✅ Instalado |
| Testes automatizados | ✅ 15/15 passando |
| Benchmark de latência | ✅ Medido (M4 Pro) |
| Diferenciação preview vs render final | ❌ Pendente |
| Distribuição (PKG/DMG/notarização) | ❌ Pendente |

---

## 3. Requisitos de sistema

### Hardware

| Especificação | Mínimo | Recomendado |
|---|---|---|
| Chip | Apple M1 | Apple M3 Pro / M4 Pro ou superior |
| RAM | 16 GB | 32 GB+ |
| Armazenamento livre | 2 GB | 5 GB (para modelos e cache CoreML) |

O Apple Silicon é requisito não-negociável: a memória unificada (UMA) elimina a cópia de dados entre CPU, GPU e ANE. Em Intel, esse pipeline não existe.

### Software

| Componente | Versão mínima validada | Versão em uso |
|---|---|---|
| macOS | 13 (Ventura) | 26 (Tahoe) |
| Final Cut Pro | 10.6.6 | 12.2 |
| Motion | 5.6.4 | 5.8+ |
| Xcode | 15 | 16 |
| FxPlug SDK | 4.1 | 4.3.4 |

**Nota macOS 26:** A partir do Tahoe, o DYLD aplica verificação de Team ID em todos os dylibs carregados no processo XPC. Todos os componentes devem ser assinados com o mesmo Developer ID. Ver SDD-02.

---

## 4. Modelos de IA

| Modelo | Fator | Arquivo | Tamanho | Entrada | Saída |
|---|---|---|---|---|---|
| RealESRGAN x2plus | 2× | `realesrgan_2x.mlmodelc` | ~33 MB | 512×512 float32 | 1024×1024 float32 |
| RealESRGAN x4plus | 4× | `realesrgan_4x.mlmodelc` | ~33 MB | 512×512 float32 | 2048×2048 float32 |

Os modelos estão convertidos do formato PyTorch original via `coremltools` com shapes **fixos** (não flexíveis). Shapes fixos são obrigatórios para execução no ANE — ver SDD-04.

Os arquivos `.mlmodelc` não estão no repositório git (binários grandes). Geração: `scripts/convert_realesrgan.py` + `xcrun coremlc compile`.

---

## 5. Parâmetros expostos no FCP Inspector

| ID | Nome | Tipo | Valores | Default |
|---|---|---|---|---|
| 1 | Scale | Popup | "2×" (0), "4×" (1) | 0 |
| 2 | Engine | Popup | "AI – Best Quality" (0), "Fast – Lanczos" (1) | 0 |
| 3 | Status | String (read-only) | "● AI Active" / "● Fast Active" / "⚠ AI unavailable – using Fast" | "● AI Active" |

---

## 6. Latência medida (M4 Pro — referência de produção)

Benchmark executado com `scripts/run_benchmark.sh` — 5 iterações por cenário, 1 descartada.

| Resolução | Escala | CoreML (AI) avg | MPS (Fast) avg | Ratio |
|---|---|---|---|---|
| 480p | 2× | 343ms | 3ms | 110× |
| 480p | 4× | 1.509ms | 7ms | 215× |
| 720p | 2× | 1.029ms | 4ms | 233× |
| 720p | 4× | 4.504ms | 15ms | 302× |
| 1080p | 2× | 2.057ms | 9ms | 224× |
| 1080p | 4× | 8.865ms | 37ms | 240× |
| 4K | 2× | 6.704ms | 38ms | 175× |
| 4K | 4× | 29.751ms | 148ms | 201× |

**Interpretação:** O motor AI não opera em tempo real em nenhum cenário. O workflow correto é: **Fast para preview/scrub na timeline, AI para render final**. Essa diferenciação ainda não está implementada (ver Seção 7).

---

## 7. Próximos passos prioritários

| Prioridade | Item | Descrição |
|---|---|---|
| 1 | Diferenciação preview/final | Usar o parâmetro `quality` em `pluginState()` para selecionar Motor Fast em preview e AI em render final. Hoje ambos usam o mesmo engine. |
| 2 | Distribuição | PKG + notarização para distribuição fora do repositório. Rascunho em `docs/distribution.md`. |
| 3 | Motion template no git | O `.moef` vive em `~/Movies/` fora do repositório. Precisa ser versionado. |
| 4 | Suporte M1 base | Validar latência e fallback em M1 (8-core GPU, 16-core ANE). |
| 5 | Super-resolução temporal | Multi-frame (usando frames vizinhos como contexto). Fora do escopo v1. |
