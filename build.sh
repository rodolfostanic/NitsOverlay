#!/bin/bash
set -e

APP="/Applications/NitsOverlay.app"
ID="br.com.stanic.NitsOverlay"
PLIST="$HOME/Library/LaunchAgents/$ID.plist"

# Encerra a instância em execução e descarrega o agente no launchd
killall NitsOverlay 2>/dev/null || true
launchctl bootout "gui/$(id -u)/$ID" 2>/dev/null || true

# Estrutura do bundle
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# Ícone: gerado apenas se ainda não existir no projeto
[ -f AppIcon.icns ] || swift generate_icon.swift AppIcon.icns
cp AppIcon.icns "$APP/Contents/Resources/"

# Info.plist — LSUIElement faz o app iniciar fora da Dock; ele entra na Dock só ao abrir a janela
cat > "$APP/Contents/Info.plist" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>NitsOverlay</string>
    <key>CFBundleIdentifier</key><string>$ID</string>
    <key>CFBundleName</key><string>NitsOverlay</string>
    <key>CFBundleShortVersionString</key><string>3.0</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>LSUIElement</key><true/>
</dict>
</plist>
EOF

# Compila e assina (usa certificado do Keychain se houver, ou assinatura ad-hoc)
echo "Compilando..."
swiftc -O NitsOverlay.swift -o "$APP/Contents/MacOS/NitsOverlay"
SIGN_ID=$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/1\)/{print $2; exit}')
codesign --force --sign "${SIGN_ID:--}" "$APP"

# Atualiza o timestamp para o macOS renovar o cache do ícone
touch "$APP"

# Recarrega o LaunchAgent no launchd se estiver ativado pelo usuário
[ -f "$PLIST" ] && launchctl bootstrap "gui/$(id -u)" "$PLIST" 2>/dev/null || true

echo "Pronto: $APP"
open "$APP"
