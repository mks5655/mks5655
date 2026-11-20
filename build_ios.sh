#!/usr/bin/env bash

# 遇到错误立即退出
set -e

echo "=================================================="
echo "🚀 开始执行 iOS 免签名 Release 打包流程"
echo "=================================================="

# 获取脚本执行时的根目录
WORKSPACE_DIR=$(pwd)
BUILD_NUMBER=${BUILD_NUMBER:-"1"}

echo "📁 工作目录: $WORKSPACE_DIR"
echo "🔢 构建编号: $BUILD_NUMBER"

# -------------------------------------------------------------
# 资产清洗：剔除桌面端平台二进制文件
# -------------------------------------------------------------
echo "--------------------------------------------------"
echo "🧹 清洗 pan_client 资产目录..."
rm -rf pan_client/assets/mihomo/windows
rm -rf pan_client/assets/mihomo/linux
rm -rf pan_client/assets/mihomo/macos

if [ -f "pan_client/pubspec.yaml" ]; then
  sed -i '' '/assets\/mihomo\/windows/d' pan_client/pubspec.yaml || true
  sed -i '' '/assets\/mihomo\/linux/d' pan_client/pubspec.yaml || true
  sed -i '' '/assets\/mihomo\/macos/d' pan_client/pubspec.yaml || true
  echo "✅ 资产清洗完成！"
fi

# -------------------------------------------------------------
# 1. 安装 Flutter 和 CocoaPods 依赖
# -------------------------------------------------------------
echo "--------------------------------------------------"
echo "📦 步骤 1: 获取 Flutter 及 CocoaPods 依赖..."
cd pan_client
flutter pub get

cd ios
pod install --repo-update
cd ../..

# -------------------------------------------------------------
# 2. 修改 Xcode 签名设置并编译 iOS App (带混淆 + 拆分符号表)
# -------------------------------------------------------------
echo "--------------------------------------------------"
echo "🛠️ 步骤 2: 禁用签名并构建 iOS Release App..."

# 清空 project.pbxproj 里的 Development Team 及证书校验[cite: 6]
sed -i '' 's/DEVELOPMENT_TEAM = .*/DEVELOPMENT_TEAM = "";/g' pan_client/ios/Runner.xcodeproj/project.pbxproj
sed -i '' 's/CODE_SIGN_IDENTITY = .*/CODE_SIGN_IDENTITY = "";/g' pan_client/ios/Runner.xcodeproj/project.pbxproj

# 传递无签名环境变量[cite: 6]
export FLUTTER_XCODE_CODE_SIGN_IDENTITY=""
export FLUTTER_XCODE_CODE_SIGNING_REQUIRED="NO"
export FLUTTER_XCODE_CODE_SIGNING_ALLOWED="NO"
export FLUTTER_XCODE_DEVELOPMENT_TEAM=""

# 创建输出与符号表保存目录[cite: 6]
mkdir -p "$WORKSPACE_DIR/output_ios"
mkdir -p "$WORKSPACE_DIR/vanguard_symbols"

cd pan_client
flutter build ios --release --no-codesign -t lib/main.dart \
  --no-tree-shake-icons \
  --obfuscate \
  --split-debug-info="$WORKSPACE_DIR/vanguard_symbols"
cd ..

# -------------------------------------------------------------
# 3. 打包 IPA 产物 (Payload 目录解压组装)
# -------------------------------------------------------------
echo "--------------------------------------------------"
echo "📦 步骤 3: 封装 IPA 文件..."

cd pan_client/build/ios/iphoneos
rm -rf Payload
mkdir -p Payload
cp -r Runner.app Payload/

IPA_NAME="pan-client-ios-v1.0.12.ipa"
zip -r -9 "$WORKSPACE_DIR/output_ios/$IPA_NAME" Payload
cd "$WORKSPACE_DIR"

echo "✅ IPA 打包成功: output_ios/$IPA_NAME"

# -------------------------------------------------------------
# 4. 打包 Crash 解析符号表 (Symbols ZIP)
# -------------------------------------------------------------
echo "--------------------------------------------------"
echo "🗜️ 步骤 4: 压缩 Debug 符号表..."

SYMBOLS_NAME="pan-client-ios-symbols-v1.0.12.zip"
zip -r -9 "output_ios/$SYMBOLS_NAME" vanguard_symbols

echo "✅ 符号表压缩成功: output_ios/$SYMBOLS_NAME"

echo "=================================================="
echo "🎉 iOS 打包完成！产物保存在目录: output_ios/"
ls -lh output_ios/
echo "=================================================="