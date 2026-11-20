#!/usr/bin/env bash

# 发生错误时立即停止执行
set -e

echo "=================================================="
echo "🚀 开始执行 Android 打包与 DEX 加固流程"
echo "=================================================="

# 1. 检查必要环境变量（密钥信息）
if [ -z "$KEYSTORE_PASSWORD" ] || [ -z "$KEYSTORE_ALIAS" ] || [ -z "$KEYSTORE_ALIAS_PASSWORD" ]; then
  echo "❌ 错误: 未设置签名所需的环境变量！"
  echo "请在运行脚本前导出以下环境变量:"
  echo "  export KEYSTORE_PASSWORD='your_store_password'"
  echo "  export KEYSTORE_ALIAS='your_key_alias'"
  echo "  export KEYSTORE_ALIAS_PASSWORD='your_key_password'"
  exit 1
fi

# 2. 准备 Android SDK 与工具链环境
export ANDROID_HOME=${ANDROID_HOME:-"/usr/local/lib/android/sdk"}
export PATH=$ANDROID_HOME/cmdline-tools/latest/bin:$ANDROID_HOME/platform-tools:$PATH
BUILD_TOOLS_VERSION="36.0.0"
BUILD_TOOLS=$ANDROID_HOME/build-tools/$BUILD_TOOLS_VERSION

# -------------------------------------------------------------
# 💡 资产清洗：在编译前剔除桌面端二进制文件
# -------------------------------------------------------------
echo "--------------------------------------------------"
echo "🧹 清洗 pan_client 资产目录..."
rm -rf pan_client/assets/mihomo/windows
rm -rf pan_client/assets/mihomo/macos
rm -rf pan_client/assets/mihomo/linux
rm -rf pan_client/android/app/src/main/jniLibs

if [ -f "pan_client/pubspec.yaml" ]; then
  sed -i '/assets\/mihomo\/windows/d' pan_client/pubspec.yaml
  sed -i '/assets\/mihomo\/macos/d' pan_client/pubspec.yaml
  sed -i '/assets\/mihomo\/linux/d' pan_client/pubspec.yaml
  echo "✅ 资产清洗完成！"
fi

# -------------------------------------------------------------
# 步骤 1：Flutter 按 ABI 架构拆分构建未签名的原包 (arm64-v8a / armeabi-v7a)
# -------------------------------------------------------------
echo "--------------------------------------------------"
echo "📦 步骤 1: Flutter 安装依赖并构建 Release APK (按 ABI 拆分)..."
cd pan_client
flutter pub get
flutter build apk --release --split-per-abi
cd ..

# -------------------------------------------------------------
# 步骤 2：使用 dpt-shell 对各 ABI 包进行 DEX 抽壳加固
# -------------------------------------------------------------
echo "--------------------------------------------------"
echo "🛡️ 步骤 2: 使用 dpt-shell 加固 APK..."

mkdir -p output_reinforced
mkdir -p dpt_tools

DPT_ZIP="dpt_tools/dpt-shell.zip"
DPT_JAR="dpt_tools/executable/dpt.jar"
DOWNLOAD_URL="https://github.com/luoyesiqiu/dpt-shell/releases/download/v2.18.0/dpt-shell-v2.18.0.zip"

if [ ! -f "$DPT_JAR" ]; then
  echo "正在下载 dpt-shell v2.18.0..."
  curl -sSL "$DOWNLOAD_URL" -o "$DPT_ZIP"
  unzip -q "$DPT_ZIP" -d dpt_tools/
fi

ABS_OUTPUT=$(realpath output_reinforced)

if [ -f "$DPT_JAR" ]; then
  # 遍历 Flutter 构建出的 arm 架构 APK
  find pan_client/build/app/outputs/flutter-apk/ -name "app-arm*-release.apk" | while read -r APK_PATH; do
    APK_NAME=$(basename "$APK_PATH")
    ABS_APK=$(realpath "$APK_PATH")
    
    echo "----------------------------------------"
    echo "正在对 $APK_NAME 进行 dpt-shell 加固..."
    
    BEFORE_COUNT=$(find "$ABS_OUTPUT" -name "*.apk" | wc -l)

    cd dpt_tools/executable
    java --add-opens java.base/java.lang=ALL-UNNAMED \
         --add-opens java.base/java.io=ALL-UNNAMED \
         -jar dpt.jar \
         -f "$ABS_APK" \
         -o "$ABS_OUTPUT" \
         -x \
         --disable-anti-debug || true
    cd ../..

    AFTER_COUNT=$(find "$ABS_OUTPUT" -name "*.apk" | wc -l)
    if [ "$AFTER_COUNT" -gt "$BEFORE_COUNT" ]; then
      echo "✅ $APK_NAME 加固成功"
    else
      echo "⚠️ $APK_NAME 加固未生成新文件，降级使用原包"
      cp "$ABS_APK" "$ABS_OUTPUT/$APK_NAME"
    fi
  done
else
  echo "⚠️ 未找到 dpt.jar，将原始包直接复制到输出目录"
  cp pan_client/build/app/outputs/flutter-apk/app-arm*-release.apk output_reinforced/
fi

# -------------------------------------------------------------
# 步骤 3：批量对齐 (zipalign) 并使用 Keystore 签名
# -------------------------------------------------------------
echo "--------------------------------------------------"
echo "🔑 步骤 3: 使用 Android apksigner 进行对齐与签名..."

mkdir -p signed_apks

# 检查可用的 Build Tools
if [ ! -f "$BUILD_TOOLS/zipalign" ]; then
  echo "❌ 错误: 未在 $BUILD_TOOLS 找到 zipalign 工具，请检查 ANDROID_HOME 及 build-tools 版本。"
  exit 1
fi

KEYSTORE_FILE="keystone"
if [ ! -f "$KEYSTORE_FILE" ]; then
  # 兼容查找当前工作目录或 android 文件夹下的 keystone
  if [ -f "pan_client/keystone" ]; then
    KEYSTORE_FILE="pan_client/keystone"
  fi
fi

for APK_PATH in output_reinforced/*.apk; do
  [ -e "$APK_PATH" ] || continue
  FILE_NAME=$(basename "$APK_PATH")
  
  # 重命名规则：app-arm64-v8a-release.apk -> pan-client-arm64-v8a-release-signed.apk
  TARGET_NAME="${FILE_NAME//app-/pan-client-}"
  TARGET_NAME="${TARGET_NAME//.apk/-signed.apk}"

  echo "----------------------------------------"
  echo "正在处理: $FILE_NAME -> $TARGET_NAME"

  # 1. 对齐
  $BUILD_TOOLS/zipalign -v -p 4 "$APK_PATH" "signed_apks/aligned_$FILE_NAME"

  # 2. 签名
  $BUILD_TOOLS/apksigner sign \
    --ks "$KEYSTORE_FILE" \
    --ks-pass pass:"$KEYSTORE_PASSWORD" \
    --ks-key-alias "$KEYSTORE_ALIAS" \
    --key-pass pass:"$KEYSTORE_ALIAS_PASSWORD" \
    --out "signed_apks/$TARGET_NAME" \
    "signed_apks/aligned_$FILE_NAME"

  # 3. 清理临时文件 & 验证
  rm -f "signed_apks/aligned_$FILE_NAME"
  echo "正在验证签名:"
  $BUILD_TOOLS/apksigner verify -v "signed_apks/$TARGET_NAME"
done

echo "=================================================="
echo "🎉 打包与加固成功！产物保存在目录: signed_apks/"
ls -lh signed_apks/
echo "=================================================="