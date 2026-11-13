#!/bin/bash
# Monta todos os apps da pasta apps/ e prepara a página de instalação em site/
set -euo pipefail
RAIZ="$(pwd)"
DONO="$(echo "${GITHUB_REPOSITORY_OWNER:-madureira-magico}" | tr "[:upper:]" "[:lower:]")"
REPO="${GITHUB_REPOSITORY#*/}"
PAGINA="https://$DONO.github.io/$REPO"
NUM="$((100 + ${GITHUB_RUN_NUMBER:-1}))"   # sempre maior que as montagens antigas (bola-app)
mkdir -p site
LINKS=""

for conf in apps/*/app.conf; do
  ID="$(basename "$(dirname "$conf")")"
  NOME=""; BUNDLE=""; VERSAO="1.0"; ESCONDER_INDICADOR=0; MANTER_ACESA=0; SEGUNDO_PLANO=0; DEITAR=0
  source "$conf"
  echo "::group::Montando $NOME ($BUNDLE)"
  T="$RAIZ/build/$ID"; rm -rf "$T"; mkdir -p "$T/App/Assets.xcassets/AppIcon.appiconset"
  cp comum/*.swift comum/*.js "$T/App/"
  [ -d "apps/$ID/extras" ] && cp -R "apps/$ID/extras/." "$T/App/" || true
  cp -R "apps/$ID/www" "$T/www"
  rm -f "$T/www/sw.js"
  cp "apps/$ID/icone.png" "$T/App/Assets.xcassets/AppIcon.appiconset/icone.png"
  cat > "$T/App/Assets.xcassets/Contents.json" <<J
{"info":{"author":"xcode","version":1}}
J
  cat > "$T/App/Assets.xcassets/AppIcon.appiconset/Contents.json" <<J
{"images":[{"filename":"icone.png","idiom":"universal","platform":"ios","size":"1024x1024"}],"info":{"author":"xcode","version":1}}
J
  if [ "$ESCONDER_INDICADOR" = "1" ]; then IND=true; else IND=false; fi
  if [ "$MANTER_ACESA" = "1" ]; then ACESA=true; else ACESA=false; fi
  if [ "$DEITAR" = "1" ]; then GIRO="[UIInterfaceOrientationPortrait, UIInterfaceOrientationLandscapeLeft, UIInterfaceOrientationLandscapeRight]"; DEITA=true; else GIRO="[UIInterfaceOrientationPortrait]"; DEITA=false; fi
  if [ "$SEGUNDO_PLANO" = "1" ]; then FUNDO="        UIBackgroundModes: [audio, bluetooth-central]"; else FUNDO=""; fi
  cat > "$T/project.yml" <<Y
name: App
options:
  deploymentTarget:
    iOS: "15.0"
targets:
  App:
    type: application
    platform: iOS
    scheme: {}
    sources:
      - path: App
      - path: www
        type: folder
        buildPhase: resources
    info:
      path: App/Info.plist
      properties:
        CFBundleDisplayName: "$NOME"
        CFBundleShortVersionString: "$VERSAO"
        CFBundleVersion: "\$(CURRENT_PROJECT_VERSION)"
        UILaunchScreen: {}
        UIRequiresFullScreen: true
        UIStatusBarHidden: true
        UIViewControllerBasedStatusBarAppearance: true
        UISupportedInterfaceOrientations: $GIRO
        NSCameraUsageDescription: "Para escolher imagens."
        NSPhotoLibraryUsageDescription: "Para escolher imagens."
        ITSAppUsesNonExemptEncryption: false
        EsconderIndicador: $IND
        ManterTelaAcesa: $ACESA
        PermiteDeitar: $DEITA
$FUNDO
        NSBluetoothAlwaysUsageDescription: "Para conversar com os aparelhos de mágica (relógio, Post-It)."
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: "$BUNDLE"
        PRODUCT_NAME: App
        TARGETED_DEVICE_FAMILY: "1"
        ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon
        SWIFT_VERSION: "5.0"
        CURRENT_PROJECT_VERSION: "$NUM"
        MARKETING_VERSION: "$VERSAO"
        CODE_SIGN_STYLE: Manual
        DEVELOPMENT_TEAM: 5S5LGDW32A
        CODE_SIGN_IDENTITY: "Apple Distribution"
        PROVISIONING_PROFILE_SPECIFIER: "Apps Magica AdHoc"
Y
  cat > "$T/ExportOptions.plist" <<P
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>ad-hoc</string>
  <key>teamID</key><string>5S5LGDW32A</string>
  <key>signingStyle</key><string>manual</string>
  <key>signingCertificate</key><string>Apple Distribution</string>
  <key>provisioningProfiles</key><dict><key>$BUNDLE</key><string>Apps Magica AdHoc</string></dict>
  <key>compileBitcode</key><false/>
  <key>stripSwiftSymbols</key><true/>
</dict></plist>
P
  ( cd "$T" && xcodegen generate \
    && xcodebuild -project App.xcodeproj -scheme App -configuration Release -sdk iphoneos \
         -destination 'generic/platform=iOS' -archivePath "$T/App.xcarchive" archive \
    && xcodebuild -exportArchive -archivePath "$T/App.xcarchive" \
         -exportOptionsPlist "$T/ExportOptions.plist" -exportPath "$T/saida" )
  mkdir -p "site/$ID"
  cp "$T/saida/App.ipa" "site/$ID/$ID.ipa"
  cp "apps/$ID/icone.png" "site/$ID/icone.png"
  cat > "site/$ID/manifest.plist" <<M
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>items</key><array><dict>
  <key>assets</key><array>
    <dict><key>kind</key><string>software-package</string><key>url</key><string>$PAGINA/$ID/$ID.ipa</string></dict>
    <dict><key>kind</key><string>display-image</string><key>url</key><string>$PAGINA/$ID/icone.png</string></dict>
    <dict><key>kind</key><string>full-size-image</string><key>url</key><string>$PAGINA/$ID/icone.png</string></dict>
  </array>
  <key>metadata</key><dict>
    <key>bundle-identifier</key><string>$BUNDLE</string>
    <key>bundle-version</key><string>$VERSAO</string>
    <key>kind</key><string>software</string>
    <key>title</key><string>$NOME</string>
  </dict>
</dict></array></dict></plist>
M
  [ -d "apps/$ID/web" ] && cp -R "apps/$ID/web/." "site/$ID/" || true
  LINKS="$LINKS<a class=\"app\" href=\"itms-services://?action=download-manifest&amp;url=$PAGINA/$ID/manifest.plist\"><img src=\"$ID/icone.png\" alt=\"\"><span><b>$NOME</b><small>Toque para instalar ou atualizar</small></span></a>"
  echo "::endgroup::"
done

DATA="$(TZ=America/Sao_Paulo date '+%d/%m/%Y %H:%M')"
cat > site/index.html <<H
<!DOCTYPE html><html lang="pt-BR"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Apps de Mágica</title>
<style>
body{margin:0;font-family:-apple-system,system-ui,sans-serif;background:#111;color:#fff;padding:28px 18px}
h1{font-size:26px;margin:0 0 6px}p{color:#aaa;margin:0 0 22px;font-size:14px}
.app{display:flex;align-items:center;gap:14px;background:#1e1e22;border-radius:16px;padding:12px;margin-bottom:12px;color:#fff;text-decoration:none}
.app img{width:60px;height:60px;border-radius:14px}.app b{display:block;font-size:18px}.app small{color:#8ab4ff;font-size:14px}
</style></head><body>
<h1>Apps de Mágica</h1><p>Montagem nº $NUM · $DATA</p>
$LINKS
</body></html>
H
