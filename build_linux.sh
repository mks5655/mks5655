#!/usr/bin/env bash

# 遇到错误立即退出
set -e

echo "=================================================="
echo "🚀 开始执行 Linux Release 打包流程"
echo "=================================================="

WORKSPACE_DIR=$(pwd)
BUILD_NUMBER=${BUILD_NUMBER:-"1"}

echo "📁 工作目录: $WORKSPACE_DIR"
echo "🔢 构建编号: $BUILD_NUMBER"

# -------------------------------------------------------------
# 1. 开启 Linux 桌面端支持 & 资产清洗
# -------------------------------------------------------------
echo "--------------------------------------------------"
echo "⚙️ 开启 Flutter Linux 桌面平台支持..."
flutter config --enable-linux-desktop

echo "🧹 清洗 pan_client 资产目录..."
rm -rf pan_client/assets/mihomo/windows
rm -rf pan_client/assets/mihomo/macos
rm -rf pan_client/assets/mihomo/linux

if [ -f "pan_client/pubspec.yaml" ]; then
  sed -i '/assets\/mihomo\/windows/d' pan_client/pubspec.yaml || true
  sed -i '/assets\/mihomo\/macos/d' pan_client/pubspec.yaml || true
  sed -i '/assets\/mihomo\/linux/d' pan_client/pubspec.yaml || true
  echo "✅ 资产清洗完成！"
fi

# -------------------------------------------------------------
# 2. 安装 Flutter 依赖 & 强制修复 Linux 项目配置
# -------------------------------------------------------------
echo "--------------------------------------------------"
echo "📦 步骤 1: 安装依赖并生成/重置 Linux 项目配置..."
cd pan_client
flutter pub get
flutter create --platforms=linux --org com.mksha --overwrite .
cd ..

# -------------------------------------------------------------
# 3. 编译 Linux Release 版本（带 Dart 混淆 + 抽离符号表）
# -------------------------------------------------------------
echo "--------------------------------------------------"
echo "🛠️ 步骤 2: 编译 Linux Release 应用..."

mkdir -p "$WORKSPACE_DIR/output_linux"
mkdir -p "$WORKSPACE_DIR/vanguard_symbols"

cd pan_client
flutter build linux --release -t lib/main.dart \
  --obfuscate \
  --split-debug-info="$WORKSPACE_DIR/vanguard_symbols"
cd ..

# -------------------------------------------------------------
# 4. 二进制 Strip（彻底剥离 C/C++ 冗余调试符号）
# -------------------------------------------------------------
echo "--------------------------------------------------"
echo "✂️ 步骤 3: 剥离 ELF 二进制调试符号 (Strip)..."

cd pan_client/build/linux/x64/release/bundle
strip --strip-unneeded pan_client || true
strip --strip-unneeded lib/*.so || true

# -------------------------------------------------------------
# 5. 打包应用主程序 (.tar.gz) 与 Debug 符号表 (.zip)
# -------------------------------------------------------------
echo "--------------------------------------------------"
echo "📦 步骤 4: 压缩打包 Release 产物..."

TAR_NAME="pan-client-linux-x64-v1.0.12.tar.gz"
tar -czvf "$WORKSPACE_DIR/output_linux/$TAR_NAME" .

cd "$WORKSPACE_DIR"
SYMBOLS_NAME="pan-client-linux-symbols-v1.0.12.zip"
zip -r -9 "output_linux/$SYMBOLS_NAME" vanguard_symbols

echo "=================================================="
echo "🎉 Linux 打包完成！产物保存在目录: output_linux/"
ls -lh output_linux/
echo "=================================================="