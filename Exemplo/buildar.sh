#!/bin/zsh
# Monta o app de laboratório NA MÃO, sem Xcode — a receita de
# memoria/sdk-swift-nativo.md virou script para o próximo agente não
# redescobrir. O entitlement entra pela seção Mach-O __TEXT,__entitlements
# (é assim que o simulador lê — codesign -d mostra vazio e ENGANA).
#
# Uso: Exemplo/buildar.sh [bundle-id]   → sai PushMeshLab.app/ ao lado do script
set -euo pipefail
cd "$(dirname "$0")/.."

BUNDLE=${1:-io.pushmesh.swiftlab}
EXEC=PushMeshLab

# Entitlement mínimo para o APNs entregar token no simulador.
cat > /tmp/pm-lab.xcent <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>aps-environment</key><string>development</string>
</dict></plist>
EOF

ARQUITETURA=$(uname -m)   # arm64 ou x86_64 — o Mac mini de T2 é x86_64
xcrun -sdk iphonesimulator swiftc \
  -target ${ARQUITETURA}-apple-ios15.0-simulator \
  -o /tmp/${EXEC} \
  Sources/PushMeshSDK/*.swift Exemplo/AppDelegate.swift \
  -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __entitlements -Xlinker /tmp/pm-lab.xcent

# Assinatura ad-hoc SEM entitlements: os entitlements moram na seção __TEXT
# (acima). Re-assinar por fora um app do Xcode MATA no simulador (SIGKILL,
# "Code Signature Invalid") — aqui é binário novo do swiftc, uma assinatura só.
cd Exemplo
rm -rf ${EXEC}.app
mkdir -p ${EXEC}.app
cp /tmp/${EXEC} ${EXEC}.app/
printf 'APPL????' > ${EXEC}.app/PkgInfo
plutil -create xml1 ${EXEC}.app/Info.plist
plutil -insert CFBundleExecutable -string ${EXEC} ${EXEC}.app/Info.plist
plutil -insert CFBundleIdentifier -string ${BUNDLE} ${EXEC}.app/Info.plist
plutil -insert CFBundleName -string ${EXEC} ${EXEC}.app/Info.plist
plutil -insert CFBundleVersion -string 1 ${EXEC}.app/Info.plist
plutil -insert CFBundleShortVersionString -string 1.0 ${EXEC}.app/Info.plist
plutil -insert CFBundlePackageType -string APPL ${EXEC}.app/Info.plist
plutil -insert UIApplicationSupportsMultipleScenes -bool false ${EXEC}.app/Info.plist
codesign -f -s - ${EXEC}.app

# Conferência: o entitlement tem de estar na seção, não na assinatura.
otool -s __TEXT __entitlements ${EXEC}.app/${EXEC} >/dev/null
echo "OK: Exemplo/${EXEC}.app (bundle ${BUNDLE}, ${ARQUITETURA})"
