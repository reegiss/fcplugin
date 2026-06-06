# Distribution Guide

## Bundle Structure

O plugin é distribuído como `AIUpscaler.app` — uma aplicação macOS padrão que contém o XPC service do FxPlug embutido.

```
AIUpscaler.app/
└── Contents/
    ├── MacOS/
    │   └── AIUpscaler                          ← wrapper app executable
    ├── Resources/
    │   ├── realesrgan_2x.mlmodelc/             ← modelos (ver nota abaixo)
    │   └── realesrgan_4x.mlmodelc/
    └── PlugIns/
        └── AIUpscaler XPC Service.pluginkit/   ← plugin real (descoberto pelo FCP via PlugInKit)
            └── Contents/
                ├── Info.plist                  ← contém ProPlugPlugInList, PlugInKit
                ├── MacOS/
                │   └── AIUpscaler XPC Service  ← executável do plugin
                ├── Frameworks/
                │   ├── FxPlug.framework/
                │   └── PluginManager.framework/
                └── Resources/
                    ├── default.metallib
                    ├── realesrgan_2x.mlmodelc/  ← modelos usados em runtime
                    └── realesrgan_4x.mlmodelc/
```

> **Nota sobre modelos duplicados:** Os modelos aparecem tanto em `AIUpscaler.app/Contents/Resources/` (Wrapper Application) quanto em `AIUpscaler XPC Service.pluginkit/Contents/Resources/` (XPC Service). O Xcode emite `warning: Skipping duplicate build file` — é esperado. O XPC Service carrega os modelos via `Bundle(for: CoreMLUpscaler.self)`, que resolve para o bundle do XPC Service. A cópia no Wrapper é redundante mas inofensiva.

---

## 1. Build Release

```bash
xcodebuild build \
  -target "Wrapper Application" \
  -project AIUpscaler/AIUpscaler.xcodeproj \
  -configuration Release \
  -destination 'platform=macOS' \
  | tail -5
```

Output esperado: `** BUILD SUCCEEDED **`

O produto fica em:
```
~/Library/Developer/Xcode/DerivedData/AIUpscaler-*/Build/Products/Release/AIUpscaler.app
```

Atalho para encontrar:
```bash
find ~/Library/Developer/Xcode/DerivedData -path "*/Release/AIUpscaler.app" -type d 2>/dev/null | head -1
```

---

## 2. Instalação Local (Desenvolvimento / QA)

O FCP usa o diretório `Application Support/Plug-ins/ProPlug` dentro do seu container de sandbox — **não** o `~/Library/Plug-Ins/FxPlug/` que a documentação antiga do FxPlug menciona.

### Instalar para o usuário atual

```bash
APP=$(find ~/Library/Developer/Xcode/DerivedData -path "*/Release/AIUpscaler.app" -type d 2>/dev/null | head -1)
# Usar o build local se DerivedData estiver vazio:
# APP=AIUpscaler/build/Release/AIUpscaler.app

INSTALL_DIR=~/Library/Containers/com.apple.FinalCutApp/Data/Library/Application\ Support/Plug-ins/ProPlug
mkdir -p "$INSTALL_DIR"
ditto "$APP" "$INSTALL_DIR/AIUpscaler.app"
```

> **Importante:** usar `ditto` (não `cp -R`) para preservar atributos estendidos e manter a assinatura de código válida.

### Verificar assinatura após instalar

```bash
codesign --verify --deep --strict \
  ~/Library/Containers/com.apple.FinalCutApp/Data/Library/Application\ Support/Plug-ins/ProPlug/AIUpscaler.app \
  && echo "OK"
```

### Verificar que o XPC service foi carregado pelo FCP

Após abrir o FCP:
```bash
pgrep -la AIUpscaler
```

Output esperado:
```
12345 AIUpscaler XPC Service
```

Se aparecer, o FCP encontrou e iniciou o plugin. Abrir o painel de Effects (⌘5) e buscar "AI Upscaler" em Video Effects.

---

## 3. Code Signing (Distribuição para Outros Usuários)

O build de debug usa `CODE_SIGN_IDENTITY = Apple Development` (válido apenas na sua máquina). Para distribuir:

### Opção A: Developer ID (distribuição direta, sem App Store)

Requer conta Apple Developer paga. Na Xcode, em cada target:
- **Signing & Capabilities → Signing Certificate:** `Developer ID Application`

Ou via linha de comando:
```bash
xcodebuild build \
  -target "Wrapper Application" \
  -project AIUpscaler/AIUpscaler.xcodeproj \
  -configuration Release \
  CODE_SIGN_IDENTITY="Developer ID Application: Seu Nome (TEAM_ID)" \
  CODE_SIGN_STYLE=Manual \
  DEVELOPMENT_TEAM=TEAM_ID
```

Após o build, verificar a assinatura:
```bash
codesign -dvvv ~/Library/Plug-Ins/FxPlug/AIUpscaler.app
codesign -dvvv ~/Library/Plug-Ins/FxPlug/AIUpscaler.app/Contents/PlugIns/"AIUpscaler XPC Service.pluginkit"
```

### Notarização (obrigatória para distribuição fora da App Store no macOS 13+)

```bash
# 1. Criar arquivo ZIP para envio
ditto -c -k --keepParent AIUpscaler.app AIUpscaler.zip

# 2. Enviar para notarização
xcrun notarytool submit AIUpscaler.zip \
  --apple-id "seu@email.com" \
  --team-id "TEAM_ID" \
  --password "@keychain:AC_PASSWORD" \
  --wait

# 3. Gravar ticket de notarização no bundle
xcrun stapler staple AIUpscaler.app

# 4. Verificar
spctl -a -v AIUpscaler.app
```

---

## 4. Criando o Instalador

### Opção A: DMG simples

```bash
# Criar DMG com o app e instrução de arrastar para a pasta certa
hdiutil create -volname "AI Upscaler" \
  -srcfolder AIUpscaler.app \
  -ov -format UDZO \
  AIUpscaler-1.0.dmg
```

O usuário arrasta `AIUpscaler.app` para `~/Library/Plug-Ins/FxPlug/` manualmente.

### Opção B: PKG com instalação automática

```bash
# Instala diretamente em /Library/Plug-Ins/FxPlug/ (requer senha de admin)
pkgbuild \
  --component AIUpscaler.app \
  --install-location "/Library/Plug-Ins/FxPlug" \
  AIUpscaler-1.0.pkg
```

Embrulhar com `productbuild` para adicionar tela de licença, logo, etc.:
```bash
productbuild \
  --distribution Distribution.xml \
  --package-path . \
  AIUpscaler-1.0-installer.pkg
```

---

## 5. Desinstalação

```bash
# Remover da pasta do usuário
rm -rf ~/Library/Plug-Ins/FxPlug/AIUpscaler.app

# Remover da pasta do sistema (requer sudo)
sudo rm -rf /Library/Plug-Ins/FxPlug/AIUpscaler.app

# Desregistrar do PlugInKit
pluginkit -r ~/Library/Plug-Ins/FxPlug/AIUpscaler.app
```

---

## 6. Checklist de Distribuição

- [ ] Build Release sem erros (`** BUILD SUCCEEDED **`)
- [ ] Testes passando (`** TEST SUCCEEDED **`, 14/14)
- [ ] Code signing com Developer ID (não Apple Development)
- [ ] Notarização completa e ticket gravado (`xcrun stapler staple`)
- [ ] `spctl -a -v AIUpscaler.app` → `accepted`
- [ ] Teste em máquina limpa: instalar, abrir FCP, confirmar plugin aparece em "Video Effects → AI Upscaler → AI Upscaler"
- [ ] Teste funcional: aplicar em clip 1080p, escala 2× e 4×, engines AI e Fast
- [ ] Verificar que nenhuma conexão de rede é feita (Activity Monitor ou `nettop`)

---

## Notas de Versão

Para atualizar a versão do plugin, editar em dois lugares:

1. `AIUpscaler/AIUpscaler/Plugin/Info.plist`:
   ```xml
   <key>version</key>
   <string>1.1</string>  <!-- em ProPlugPlugInList -->
   ```

2. `AIUpscaler/AIUpscaler/Wrapper Application/Info.plist`:
   ```xml
   <key>CFBundleShortVersionString</key>
   <string>1.1</string>
   <key>CFBundleVersion</key>
   <string>2</string>  <!-- incrementar a cada build de distribuição -->
   ```

O PlugInKit usa `CFBundleVersion` para resolver conflitos entre versões instaladas — versão maior vence.
