#!/usr/bin/env bash

# ==============================================================================
# 构建脚本: 单独编译 macOS x86_64 (AMD64 / Intel 架构) Release 包
# ==============================================================================

set -euo pipefail

# 1. 配置路径与变量
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$SCRIPT_DIR"
CLIENT_DIR="$PROJECT_ROOT/pan_client"
MACOS_DIR="$CLIENT_DIR/macos"

OUTPUT_DIR="$PROJECT_ROOT/output_macos"
SYMBOLS_DIR="$PROJECT_ROOT/vanguard_symbols"

# 动态版本号
BUILD_NUMBER="${GITHUB_RUN_NUMBER:-1}"
VERSION="1.0.${BUILD_NUMBER}"
APP_NAME="PCloud"

echo "================================================================="
echo "开始构建 macOS x86_64 (Intel/AMD64) Release 包: $APP_NAME (v$VERSION)"
echo "================================================================="

# 2. 初始化产物与符号存储目录
rm -rf "$OUTPUT_DIR" "$SYMBOLS_DIR"
mkdir -p "$OUTPUT_DIR" "$SYMBOLS_DIR"

# 3. 启用 macOS 桌面支持
flutter config --enable-macos-desktop

# 4. 资产清洗 (兼容 macOS BSD sed 语法)
echo "[1/5] 清理无关平台二进制资产 (mihomo/windows, mihomo/linux)..."
rm -rf "$CLIENT_DIR/assets/mihomo/windows"
rm -rf "$CLIENT_DIR/assets/mihomo/linux"

if [ -f "$CLIENT_DIR/pubspec.yaml" ]; then
    sed -i '' '/assets\/mihomo\/windows/d' "$CLIENT_DIR/pubspec.yaml" || true
    sed -i '' '/assets\/mihomo\/linux/d' "$CLIENT_DIR/pubspec.yaml" || true
fi

# 5. 安装依赖 (Flutter Pub & CocoaPods)
echo "[2/5] 安装 Flutter 与 macOS CocoaPods 依赖..."
cd "$CLIENT_DIR"
flutter pub get

cd "$MACOS_DIR"
pod install

# 强制禁用 Ad-Hoc 签名限制（CI 环境兼容）
export CODE_SIGN_IDENTITY="-"
export CODE_SIGNING_REQUIRED="NO"
export CODE_SIGNING_ALLOWED="NO"

# 6. 单独编译 x86_64 架构
echo "[3/5] 开始编译 x86_64 架构 Flutter 应用..."
cd "$CLIENT_DIR"
export ARCHS="x86_64"
export ONLY_ACTIVE_ARCH="NO"

flutter build macos --release \
    -t lib/main.dart \
    --obfuscate \
    --split-debug-info="$SYMBOLS_DIR"

APP_PATH="$CLIENT_DIR/build/macos/Build/Products/Release/${APP_NAME}.app"
EXECUTABLE="$APP_PATH/Contents/MacOS/${APP_NAME}"

if [ ! -d "$APP_PATH" ] || [ ! -f "$EXECUTABLE" ]; then
    echo "错误: 未能找到生成的 App 文件：$APP_PATH"
    exit 1
fi

# 校验二进制架构
ARCH_INFO="$(lipo -info "$EXECUTABLE")"
echo "架构分析: $ARCH_INFO"
if [[ "$ARCH_INFO" != *"x86_64"* ]]; then
    echo "错误: 编译产物非 x86_64 架构！"
    exit 1
fi

# 7. Strip 剥离符号精简体积
echo "[4/5] 剥离调试符号以缩小体积..."
set +e
strip -x "$APP_PATH/Contents/MacOS/"* 2>/dev/null || true
if [ -d "$APP_PATH/Contents/Frameworks" ]; then
    find "$APP_PATH/Contents/Frameworks" -type f -perm -111 -exec strip -x {} \; 2>/dev/null || true
fi
set -e


# ==============================================================================
# 💡 关键新增：Strip 剥离符号后，必须重新进行 Ad-hoc 深度签名，避免崩溃 (zsh: killed)
# ==============================================================================
echo "正在对应用进行 Ad-hoc 重新签名..."
codesign --force --deep --sign - "$APP_PATH"


# 8. 打包产物 (Zip / DMG / Debug Symbols)
echo "[5/5] 打包构建产物..."
ZIP_NAME="pan-client-macos-x86_64-release.zip"
DMG_NAME="pan-client-macos-x86_64-release.dmg"

# 打包为 ZIP (保留 macOS 元数据)
cd "$CLIENT_DIR/build/macos/Build/Products/Release"
ditto -c -k --sequesterRsrc --keepParent "${APP_NAME}.app" "$OUTPUT_DIR/$ZIP_NAME"

# 生成 DMG 镜像 (如环境预装 create-dmg)
if command -v create-dmg &> /dev/null; then
    create-dmg \
      --volname "$APP_NAME Installer (x86_64)" \
      --window-pos 200 120 \
      --window-size 600 400 \
      --icon-size 100 \
      --icon "${APP_NAME}.app" 175 120 \
      --hide-extension "${APP_NAME}.app" \
      --app-drop-link 425 120 \
      "$OUTPUT_DIR/$DMG_NAME" \
      "$CLIENT_DIR/build/macos/Build/Products/Release/${APP_NAME}.app" || true
fi

# 打包 Debug 符号表
cd "$PROJECT_ROOT"
zip -r -9 "$OUTPUT_DIR/pan-client-macos-x86_64-symbols.zip" vanguard_symbols

echo "================================================================="
echo "✅ x86_64 单架构编译完成！产物列表如下 ($OUTPUT_DIR):"
echo "================================================================="
ls -lh "$OUTPUT_DIR"
