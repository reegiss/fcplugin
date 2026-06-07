# Backlog de Otimização — AI Upscaler Plugin

**Fonte de referência:** Notebook "Restoring Image Quality With AI using Real-ESRGAN, SwinIR and BSRGAN" (Entreprenerdly.com)
**Atualizado:** 2026-06-07

---

## Contexto: o que o notebook demonstra

O notebook compara três arquiteturas de super-resolução 4× em imagens reais do dataset RealSRSet (ICCV2021):

| Modelo | Arquitetura | Força observada | Fraqueza observada |
|---|---|---|---|
| **RealESRGAN x4plus** | RRDB (CNN) | Texturas, detalhes gerais | Pode over-sharpen faces |
| **BSRGAN** | RRDB com degradação cega | Faces, restauração de fotos antigas | Arquitetura/construções |
| **SwinIR-Large** | Swin Transformer | Estruturas, bordas lineares, texto | Mais pesado computacionalmente |

O parâmetro do BSRGAN revelado no log: `[3, 3, 64, 23, 32, 4]` = `[in_ch, out_ch, num_features, num_RRDB_blocks, num_grow_ch, scale]`. Backbone idêntico ao RealESRGAN — a diferença está nos dados de treinamento (degradações sintéticas diferentes).

**Conclusão central do notebook:** nenhum modelo é universalmente melhor. O conteúdo do vídeo determina qual modelo produz melhor resultado. Isso tem implicação direta no roadmap do plugin.

---

## Itens de backlog derivados

---

### OPT-01 — SwinIR como motor alternativo

**Conceito:** SwinIR usa Swin Transformer com janelas de atenção deslocada (`shifted window attention`, janela 8×8, patch 64). Em vez de convolução local, ele modela dependências de longo alcance — o que produz resultados superiores em conteúdo estrutural (texto, bordas, arquitetura).

**Por que importa para vídeo profissional:** Vídeos corporativos, documentários e conteúdo com texto na tela se beneficiam da capacidade do Swin de preservar retas e caracteres. RealESRGAN tende a suavizar bordas lineares.

**Desafio técnico (CoreML):**
- Transformers com `scaled_dot_product_attention` têm suporte limitado no ANE no CoreML — podem forçar fallback para GPU/CPU.
- O modelo Large (`SwinIR-L`) tem ~28M parâmetros — significativamente maior que RealESRGAN (~16M).
- Conversão com `coremltools` requer atenção ao `window_size` e ao `img_size` de entrada: o modelo espera múltiplos de 64.

**Ação:**
1. Converter `003_realSR_BSRGAN_DFOWMFC_s64w8_SwinIR-L_x4_GAN.pth` via `coremltools`
2. Testar se executa no ANE (verificar via Instruments → Core ML)
3. Se cair para GPU: medir latência e decidir se vale como opção "Premium Quality"
4. Tile size para SwinIR: múltiplos de 64 — testar 448×448 ou 512×512 (já compatível)

**Estimativa:** 20–30h (conversão + validação ANE + integração no Inspector)

---

### OPT-02 — BSRGAN como motor para conteúdo de faces/pessoas

**Conceito:** BSRGAN foi treinado com um processo de degradação cega mais agressivo e variado que o RealESRGAN. Resultado: superior em restauração de rostos, fotos antigas e imagens com ruído misto. O notebook demonstra isso em `foreman.png` e `oldphoto6.png`.

**Relevância:** Entrevistas, documentários, talking heads — conteúdo de vídeo profissional majoritariamente focado em pessoas.

**Diferença de arquitetura vs RealESRGAN:** Mínima (mesmo RRDB backbone). Os pesos `.pth` são intercambiáveis. A conversão CoreML é idêntica à que já fizemos para RealESRGAN.

**Ação:**
1. Baixar `BSRGAN.pth` (GitHub: cszn/KAIR)
2. Converter com o mesmo `scripts/convert_realesrgan.py` (ajustar config: `[3, 3, 64, 23, 32, 4]`)
3. Adicionar `realesrgan_bsrgan_4x.mlmodelc` ao bundle
4. Expor como terceira opção no parâmetro Engine: "AI – Faces" (ao lado de "AI – Best Quality" e "Fast – Lanczos")

**Estimativa:** 10–15h (conversão + UI + testes)

---

### OPT-03 — Seleção automática de modelo por tipo de conteúdo

**Conceito derivado do notebook:** A qualidade final depende da correspondência entre o modelo e o conteúdo. O notebook deixa essa escolha para o usuário — mas em um plugin de timeline, essa decisão pode ser automatizada.

**Abordagem:**
- Analisar o frame de entrada antes de escolher o motor
- Heurísticas baseadas em características extraíveis via Metal/Vision:
  - Alta frequência de bordas lineares → SwinIR
  - Presença de faces detectadas (Vision `VNDetectFaceRectanglesRequest`) → BSRGAN
  - Conteúdo geral → RealESRGAN

**Limitação prática:** A análise adiciona latência por frame. Viável apenas se feita no preview path (engine Fast já roda em <150ms) e cacheada por cena.

**Ação (longo prazo):**
1. Implementar detector de características via Metal compute shader (detecção de bordas tipo Sobel + análise de espectro de frequência)
2. Cache de decisão por `CMTime` — não reanalisar o mesmo frame
3. Expor como modo "Auto" no Inspector (Engine = Auto / AI – Faces / AI – Best Quality / Fast)

**Estimativa:** 40–60h (pesquisa + implementação + testes de qualidade)

---

### OPT-04 — Tamanho de tile aumentado (640×640 ou 768×768)

**Conceito do notebook:** O RealESRGAN é chamado com `--tile 800` e o SwinIR com `--tile 640` quando em modo patch-wise. Nosso plugin usa 512×512 fixo (imposto pelos shapes do CoreML).

**Por que tile maior pode ajudar:**
- Menos tiles por frame → menos overhead de extração, batch e reconstrução
- Menos tiles de borda → menos chamadas a `mpsResize` → melhor qualidade nas bordas
- Para 1080p com tiles de 640: 3 colunas × 2 linhas = 6 tiles (vs 12 tiles com 512)

**Custo:**
- O modelo CoreML teria shape `[1, 3, 640, 640]` — compilar uma segunda variante
- Memória por tile: 640×640×3×2 bytes (float16) = ~2.3MB entrada + ~9.2MB saída (4×) = mais pressão de RAM
- Latência por tile aumenta proporcionalmente à área: ~56% maior que 512×512

**Trade-off real para 1080p 4×:**
- 512px: 12 tiles × 8.9s total ÷ 12 = ~740ms/tile
- 640px: 6 tiles, mas ~1.170ms/tile estimado → total ~7s — ganho marginal (~20%)
- 640px: 6 tiles de borda (vs 12) → menos `mpsResize` → melhor qualidade

**Ação:**
1. Gerar variante do modelo com shape 640×640
2. Benchmark comparativo: 512px vs 640px (latência + qualidade visual nas bordas)
3. Expor como configuração avançada ou selecionar automaticamente baseado na VRAM disponível

**Estimativa:** 15–20h

---

### OPT-05 — Face enhancement separado (GFPGAN)

**Conceito do notebook:** O RealESRGAN suporta `--face_enhance` que aplica GFPGAN separadamente após o upscale — um modelo especializado em restauração facial que corrige olhos, dentes e pele com precisão cirúrgica. Os dois modelos são complementares: RealESRGAN faz o upscale geral, GFPGAN refina as regiões faciais.

**Abordagem para o plugin:**
1. `VNDetectFaceRectanglesRequest` (Vision framework) detecta bounding boxes de rostos no frame
2. Para cada rosto detectado: aplicar GFPGAN (convertido para CoreML) na região
3. Blitar o resultado de volta sobre o frame upscalado via Metal

**Complexidade técnica:**
- GFPGAN: arquitetura StyleGAN2-based — conversão CoreML é não-trivial
- Requer dois modelos carregados simultaneamente → pico de memória maior
- Detecção facial deve ser rápida o suficiente para não dominar o tempo total

**Candidato para v2 do produto:** Diferencial comercial significativo — "AI Upscaling + Face Restoration" é uma proposta de valor clara para editores de documentários e entrevistas.

**Estimativa:** 60–80h (complexidade da conversão GFPGAN + pipeline de detecção)

---

### OPT-06 — Quantização INT8 para reduzir latência

**Conceito do notebook (implícito):** O notebook usa modelos FP32 em GPU CUDA. Nossa implementação usa FP16 via `MLMultiArray`. A próxima etapa é INT8.

**CoreML suporta quantização pós-treinamento:**
```python
import coremltools as ct

config = ct.optimize.coreml.OptimizationConfig(
    global_config=ct.optimize.coreml.OpLinearQuantizerConfig(
        mode="linear_symmetric",
        dtype="int8",
        granularity="per_channel"
    )
)
compressed = ct.optimize.coreml.linear_quantize_weights(model, config)
```

**Ganho esperado:**
- Redução de tamanho: ~33MB → ~16MB por modelo
- Latência ANE: potencialmente 20–40% menor (ANE tem throughput maior para INT8)
- Qualidade: perda mínima em super-resolução (validar via PSNR/SSIM)

**Ação:**
1. Gerar variante INT8 dos modelos existentes (x2plus, x4plus)
2. Benchmark comparativo: FP16 vs INT8 (latência + PSNR em RealSRSet)
3. Se qualidade aceitável: substituir FP16 como padrão

**Estimativa:** 8–12h

---

### OPT-07 — 2× de RealESRGAN x2plus vs x4plus com downscale

**Conceito:** O notebook usa apenas o modelo x4plus. Nosso plugin tem x2plus nativo. Mas existe uma terceira estratégia: usar x4plus e redimensionar para 2× na saída — potencialmente melhor qualidade que o x2plus, pois o modelo x4plus tem mais capacidade de representação.

**Hipótese a testar:**
- `x4plus(frame) → Lanczos 50%` vs `x2plus(frame)` — qual produz melhor PSNR?
- Se x4plus+downscale vencer: simplificar para um único modelo (reduz bundle ~33MB)

**Ação:**
1. Processar RealSRSet com ambas as estratégias
2. Calcular PSNR/SSIM com ground truth
3. Decisão: manter dois modelos ou unificar

**Estimativa:** 5h

---

## Priorização sugerida

| Prioridade | Item | Impacto | Esforço | Pré-requisito |
|---|---|---|---|---|
| 1 | OPT-02 — BSRGAN | Alto (diferencial imediato) | Baixo | Nenhum |
| 2 | OPT-06 — Quantização INT8 | Alto (latência) | Baixo | Nenhum |
| 3 | OPT-04 — Tile 640×640 | Médio (qualidade borda) | Médio | OPT-06 |
| 4 | OPT-07 — x4plus vs x2plus | Médio (simplificação) | Baixo | OPT-06 |
| 5 | OPT-01 — SwinIR | Alto (qualidade estrutural) | Alto | Nenhum |
| 6 | OPT-03 — Seleção automática | Alto (UX) | Alto | OPT-01 + OPT-02 |
| 7 | OPT-05 — Face Enhancement | Muito alto (produto v2) | Muito alto | OPT-02 + OPT-03 |

---

## Métricas de avaliação

Para validar cada otimização objetivamente, usar o dataset **RealSRSet** (6 imagens canônicas do paper BSRGAN/ICCV2021):

```bash
# Disponível em:
# https://github.com/JingyunLiang/SwinIR/releases/download/v0.0/RealSRSet+5images.zip
```

Métricas a coletar por variante:
- **PSNR** (Peak Signal-to-Noise Ratio) — fidelidade de pixel
- **SSIM** (Structural Similarity Index) — percepção estrutural
- **Latência média** (via `scripts/run_benchmark.sh`)
- **Pico de memória** (via Activity Monitor / Instruments)
