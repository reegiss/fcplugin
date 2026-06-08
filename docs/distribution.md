# Distribution Guide — AI Upscaler for Final Cut Pro

**Versão:** 1.1 | **Atualizado:** 2026-06-07

Pipeline completo: build → assinar → notarizar → PKG → DMG.

---

## Visão geral do pipeline

```
xcodebuild (Release, arm64)
    │
    ▼
codesign --verify --deep          ← valida assinatura Developer ID
    │
    ▼
Montar payload PKG
    ├── /Library/Plug-Ins/FxPlug/AIUpscaler.app
    └── /Library/Application Support/AI Upscaler/AI Upscaler.moef
    │
    ▼
pkgbuild (component package)      ← assina com Developer ID Installer
    │
    ▼
productbuild (distribution .pkg)  ← injeta Distribution.xml + Resources
    │
    ▼
notarytool submit --wait          ← submete para servidores Apple (~2 min)
    │
    ▼
stapler staple                    ← grafa ticket de notarização no .pkg
    │
    ▼
hdiutil create                    ← empacota em DMG comprimido
    │
    ▼
dist/AIUpscaler-1.1.dmg  ✓
```

---

## Pré-requisitos

### Certificados (Keychain)

| Certificado | Usado por | Como obter |
|---|---|---|
| `Developer ID Application: ...` | Xcode build (sign .app) | developer.apple.com → Certificates |
| `Developer ID Installer: ...` | pkgbuild + productbuild | developer.apple.com → Certificates |

Verificar presença:
```bash
security find-identity -v -p codesigning | grep "Developer ID Application"
security find-identity -v -p basic      | grep "Developer ID Installer"
```

### Credenciais para notarização (uma vez)

```bash
./scripts/setup_notarytool.sh
# Segue prompt interativo; armazena no keychain como perfil "AIUpscaler"
```

---

## Estrutura de arquivos

```
scripts/
  build_pkg.sh                    ← pipeline principal (executar este)
  setup_notarytool.sh             ← configuração inicial do keychain
  pkg/
    Distribution.xml              ← layout do installer macOS
    scripts/
      preinstall                  ← remove instalação anterior
      postinstall                 ← lsregister + PlugInKit + Motion template
    Resources/
      welcome.html                ← tela de boas-vindas do installer
      license.rtf                 ← licença de uso
      background.png              ← imagem de fundo (opcional — colocar aqui)
templates/
  AI Upscaler.moef                ← Motion template (versionado aqui)
dist/                             ← output do pipeline (gitignored)
  AIUpscaler-1.1.pkg
  AIUpscaler-1.1.dmg
```

---

## Executar o pipeline

### Build completo (com notarização + DMG)

```bash
DEVELOPER_ID_APP="Developer ID Application: Regis Melo (XXXXXXXXXX)" \
DEVELOPER_ID_INSTALLER="Developer ID Installer: Regis Melo (XXXXXXXXXX)" \
NOTARYTOOL_PROFILE="AIUpscaler" \
VERSION="1.1" \
./scripts/build_pkg.sh
```

### Build rápido para teste local (sem notarização, sem DMG)

```bash
DEVELOPER_ID_APP="Developer ID Application: Regis Melo (XXXXXXXXXX)" \
DEVELOPER_ID_INSTALLER="Developer ID Installer: Regis Melo (XXXXXXXXXX)" \
VERSION="1.1" \
./scripts/build_pkg.sh --skip-notarize --skip-dmg
```

### Apenas PKG, sem DMG

```bash
./scripts/build_pkg.sh --skip-dmg
```

---

## O que o postinstall faz

O script `scripts/pkg/scripts/postinstall` roda como root após a instalação do payload:

1. **`lsregister`** — registra o `.app` com LaunchServices (necessário para o macOS reconhecer o bundle).

2. **`open AIUpscaler.app`** — lança o wrapper uma vez e encerra em seguida. Isso é obrigatório: sem ele, o PlugInKit nunca indexa o XPC Service e o FCP não encontra o plugin.

3. **Motion template** — copia `AI Upscaler.moef` de `/Library/Application Support/AI Upscaler/` para `~/Movies/Motion Templates.localized/Effects.localized/AI Upscaler.localized/` do usuário logado.

Sem os passos 2 e 3, o plugin instala mas não aparece no FCP.

---

## O que o installer instala

| Destino | Conteúdo |
|---|---|
| `/Library/Plug-Ins/FxPlug/AIUpscaler.app` | Plugin completo (XPC service + modelos CoreML) |
| `/Library/Application Support/AI Upscaler/AI Upscaler.moef` | Template temporário (copiado ao home no postinstall) |
| `~/Movies/Motion Templates.localized/…/AI Upscaler.moef` | Template do Motion (copiado pelo postinstall) |

**Requer admin.** O installer pede senha de administrador porque escreve em `/Library/`.

---

## Estrutura do bundle

```
AIUpscaler.app/
└── Contents/
    ├── MacOS/AIUpscaler                ← wrapper mínimo
    ├── Info.plist
    └── PlugIns/
        └── AIUpscalerXPC.xpc/
            └── Contents/
                ├── MacOS/AIUpscalerXPC ← lógica do plugin
                ├── Info.plist           ← PlugInKit + ProPlugPlugInList
                ├── Resources/
                │   ├── realesrgan_2x.mlmodelc
                │   ├── realesrgan_4x.mlmodelc
                │   └── default.metallib
                └── Frameworks/
                    ├── FxPlug.framework
                    └── PluginManager.framework
```

---

## Verificação pós-instalação

```bash
# 1. Verificar que o plugin está registrado no PlugInKit
pluginkit -m -i "info.regismelo.AIUpscaler.XPCService"
# Esperado: info.regismelo.AIUpscaler.XPCService(1.1)

# 2. Verificar assinatura do .app instalado
codesign --verify --deep --strict --verbose=2 \
    /Library/Plug-Ins/FxPlug/AIUpscaler.app

# 3. Verificar assinatura do .pkg
pkgutil --check-signature dist/AIUpscaler-1.1.pkg

# 4. Verificar notarização
spctl --assess --type install --verbose=2 dist/AIUpscaler-1.1.pkg
```

---

## Troubleshooting

| Sintoma | Causa provável | Solução |
|---|---|---|
| Plugin não aparece no FCP | PlugInKit não indexado | Verificar que o postinstall rodou; re-lançar AIUpscaler.app manualmente |
| `lsregister` falha no postinstall | Caminho do framework mudou | Ajustar `LSREGISTER` no script postinstall |
| Notarização retorna `Invalid` | Assinatura ad-hoc ou sem hardened runtime | Nunca usar `-` como identidade; verificar `ENABLE_HARDENED_RUNTIME=YES` |
| DYLD crash ao abrir XPC | Team IDs diferentes entre .app e frameworks | Garantir que `${EXPANDED_CODE_SIGN_IDENTITY}` é usado nos build phases |
| Motion template não aparece no FCP | `.moef` não copiado para `~/Movies/` | Verificar log do postinstall; copiar manualmente e reiniciar FCP |
| `pkgutil: no such pkg` | PKG corrompido | Re-executar o pipeline do zero |

---

## Checklist de release

Antes de entregar ao cliente:

- [ ] `xcodebuild test` — todos os testes passando
- [ ] Build Release sem warnings de signing
- [ ] `codesign --verify --deep` no .app
- [ ] `pkgutil --check-signature` no .pkg
- [ ] `spctl --assess --type install` no .pkg (notarização válida)
- [ ] Instalar em máquina limpa e verificar PlugInKit
- [ ] Abrir FCP, confirmar efeito em **Efeitos > AI Upscaler**
- [ ] Testar aplicação do efeito em clip de 1080p
- [ ] Confirmar que o uninstall manual funciona (remover .app + .moef)
- [ ] Atualizar `VERSION` no build e no `Info.plist` do Xcode
