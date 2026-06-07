# SDD-02 — Arquitetura

**Versão:** 2.0 | **Status:** Implementado e validado | **Atualizado:** 2026-06-07

---

## 1. Visão geral da estrutura

O plugin é um **bundle XPC out-of-process** empacotado dentro de uma aplicação wrapper. O Final Cut Pro nunca executa o código do plugin diretamente — ele se comunica via XPC com o processo isolado.

```
AIUpscalerV2.app                        ← Wrapper Application (entrada no sistema)
└── Contents/
    ├── MacOS/AIUpscalerV2              ← Binário wrapper (AppDelegate mínimo)
    └── PlugIns/
        └── AIUpscalerXPC.xpc           ← Serviço XPC (o plugin de verdade)
            └── Contents/
                ├── MacOS/AIUpscalerXPC ← Binário da inferência
                ├── Info.plist          ← Declaração PlugInKit (crítico)
                ├── Resources/
                │   ├── realesrgan_2x.mlmodelc
                │   └── realesrgan_4x.mlmodelc
                └── Frameworks/
                    ├── FxPlug.framework
                    └── PluginManager.framework
```

**Por que out-of-process importa:** Se o XPC crashar (overflow de memória durante inferência, bug de shader), o FCP continua rodando. O Jetsam do macOS encerra o XPC sem afetar o projeto do editor.

---

## 2. Descoberta pelo PlugInKit — sequência obrigatória

O FCP não varre diretórios. Ele consulta o PlugInKit, que mantém um índice de extensões registradas. A sequência de instalação é:

```bash
# 1. Copiar o .app para o local correto
cp -R AIUpscalerV2.app ~/Library/Plug-Ins/FxPlug/

# 2. Registrar com LaunchServices
lsregister -f -R -trusted ~/Library/Plug-Ins/FxPlug/AIUpscalerV2.app

# 3. OBRIGATÓRIO: lançar o wrapper uma vez para indexar o XPC
open ~/Library/Plug-Ins/FxPlug/AIUpscalerV2.app

# 4. Verificar registro
pluginkit -m -i "info.regismelo.AIUpscalerV2.XPCService"
# Saída esperada: info.regismelo.AIUpscalerV2.XPCService(1.1)
```

**Passo 3 é frequentemente esquecido.** Sem lançar o wrapper, o PlugInKit nunca indexa o XPC e o FCP não encontra o plugin.

---

## 3. Info.plist do XPC — campos críticos

Dois erros nesse arquivo tornam o plugin invisível sem mensagem de erro:

```xml
<!-- CORRETO: usar PlugInKit, não NSExtension -->
<key>PlugInKit</key>
<dict>
    <key>Protocol</key>
    <string>PROXPCProtocol</string>
    <key>PrincipalClass</key>
    <string>FxPrincipal</string>
    <key>Attributes</key>
    <dict>
        <key>com.apple.protocol</key>
        <string>FxPlug</string>
        <key>com.apple.version</key>
        <string>1.1</string>
    </dict>
</dict>

<!-- CORRETO: FxFilter, não FxTileableEffect -->
<!-- FxTileableEffect é o protocolo Swift — FxFilter é o nome de categoria do FCP -->
<key>protocolNames</key>
<array>
    <string>FxFilter</string>
</array>
```

Usar `NSExtension` no lugar de `PlugInKit`, ou `FxTileableEffect` no lugar de `FxFilter`, resulta em plugin silenciosamente ignorado pelo FCP.

---

## 4. Assinatura de código — restrições macOS 26

No macOS 26 (Tahoe), o DYLD valida que todos os dylibs carregados no processo compartilham o mesmo Team ID do executável. Isso afeta o XPC porque ele carrega `FxPlug.framework` e `PluginManager.framework` do bundle.

**Regras:**
- **Nunca usar `CODE_SIGN_IDENTITY="-"` (ad-hoc).** Causa crash DYLD no launch do XPC com erro de Team ID.
- Todos os targets devem usar o mesmo Developer ID certificate.
- Os build phases que copiam os frameworks usam `${EXPANDED_CODE_SIGN_IDENTITY}` — variável que herda o certificado do projeto. Não hardcodar.
- `ENABLE_HARDENED_RUNTIME = YES` em todos os targets (obrigatório para coincidir com os frameworks pré-compilados).
- `ENABLE_APP_SANDBOX = NO` no XPC Service. FxPlug XPC services não são App Extensions e não devem ser sandboxed.

**Comando de build correto:**
```bash
xcodebuild build \
  -scheme "Wrapper Application" \
  -project AIUpscaler/AIUpscaler.xcodeproj \
  -destination 'platform=macOS,arch=arm64' \
  -configuration Release \
  ARCHS=arm64
```

---

## 5. Motion template — obrigatório para visibilidade no FCP

**Plugins FxPlug aparecem no Motion mas NÃO no browser de efeitos do FCP diretamente.** Para usar no FCP, é necessário um Motion template (`.moef`):

```
~/Movies/Motion Templates.localized/Effects.localized/
└── AI Upscaler.localized/
    └── AI Upscaler.moef         ← Referencia o plugin pelo UUID
```

O `.moef` é XML que referencia o plugin pelo `pluginUUID`:

```xml
<filter name="AI Upscaler"
        pluginUUID="C1D48F7E-1867-42C3-9C89-9329EA2E1E9D"
        pluginVersion="1"
        pluginName="AIUpscalerPlugIn">
```

O UUID deve coincidir com o campo `pluginUUID` no `ProPlugPlugInList` do `Info.plist`. Após instalar o template, reiniciar o FCP faz o efeito aparecer na aba **AI Upscaler**.

**Pendência:** O arquivo `.moef` vive fora do repositório. Precisa ser versionado.

---

## 6. Estrutura de targets no Xcode

| Target | Tipo | Responsabilidade |
|---|---|---|
| Wrapper Application | macOS App | Contêiner. Hospeda o XPC, registra no PlugInKit. |
| XPC Service | XPC Service | Plugin de verdade. Roda `UpscalerEffect` fora do processo do FCP. |
| AIUpscalerTests | Unit Test Bundle | Importa módulo do Wrapper para testar Engine e TileProcessor. |

**Nota de compilação:** `import FxPlug` não existe em Swift. Os tipos FxPlug (`FxTileableEffect`, `FxImageTile`, `FxRect`, etc.) vêm exclusivamente do ObjC bridging header (`XPC Service-Bridging-Header.h`). SourceKit reporta falsos "Cannot find type" para esses tipos — ignorar. Usar `xcodebuild build` para validar compilação.

---

## 7. Fluxo de comunicação por frame

```
FCP (processo do editor)
  │
  │  XPC (IPC serializado — lightweight: apenas StateData ~8 bytes)
  ▼
AIUpscalerXPC (processo isolado)
  │
  ├─ pluginState()              → serializa parâmetros do inspector
  ├─ destinationImageRect()     → declara dimensões de saída (W*scale, H*scale)
  ├─ sourceTileRect()           → informa ROI necessária da fonte
  └─ renderDestinationImage()   → executa o pipeline GPU completo
       │
       ├─ FxImageTile → MTLTexture (via IOSurface, zero-copy entre processos)
       ├─ TileProcessor.process()
       │    ├─ extractAllTiles()     → blit → texturas por tile
       │    ├─ engine.upscaleBatch() → CoreML (ANE) ou MPS (GPU)
       │    └─ gpuReconstruct()      → feather blend → textura final
       └─ blit resultado → destTexture
```
