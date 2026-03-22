#!/bin/bash

# AI Agent Hub - 多平台构建脚本
# 构建 Android, iOS, macOS, Web, Windows 应用包

set -e  # 遇到错误时退出

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 项目信息
PROJECT_NAME="shepaw"
VERSION="1.0.0"
BUILD_DIR="build"
OUTPUT_DIR="dist"

# 打印带颜色的消息
print_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# 检查命令是否存在
check_command() {
    if ! command -v "$1" &> /dev/null; then
        print_error "命令 '$1' 未找到，请安装后重试"
        exit 1
    fi
}

# 检查 Flutter 环境
check_flutter() {
    print_info "检查 Flutter 环境..."
    check_command flutter
    
    # 检查 Flutter 版本
    FLUTTER_VERSION=$(flutter --version | head -1)
    print_info "Flutter 版本: $FLUTTER_VERSION"
    
    # 检查 Flutter 医生
    print_info "运行 Flutter doctor 检查环境..."
    flutter doctor -v
}

# 准备构建环境
prepare_build() {
    print_info "准备构建环境..."
    
    # 创建输出目录
    mkdir -p "$OUTPUT_DIR"
    
    # 清理构建目录
    print_info "清理构建目录..."
    rm -rf "$BUILD_DIR"
    
    # 获取依赖
    print_info "获取项目依赖..."
    flutter pub get
}

# 构建 Android APK
build_android_apk() {
    print_info "开始构建 Android APK..."
    
    # 构建 debug APK
    print_info "构建 debug APK..."
    flutter build apk --debug
    
    # 复制 APK 到输出目录
    cp "build/app/outputs/flutter-apk/app-debug.apk" "$OUTPUT_DIR/${PROJECT_NAME}-debug.apk"
    print_success "Android debug APK 已生成: $OUTPUT_DIR/${PROJECT_NAME}-debug.apk"
    
    # 构建 release APK（需要签名配置）
    print_info "构建 release APK..."
    if [ -f "android/key.properties" ]; then
        flutter build apk --release
        cp "build/app/outputs/flutter-apk/app-release.apk" "$OUTPUT_DIR/${PROJECT_NAME}-release.apk"
        print_success "Android release APK 已生成: $OUTPUT_DIR/${PROJECT_NAME}-release.apk"
    else
        print_warning "未找到 android/key.properties 文件，跳过 release APK 构建"
        print_warning "请创建 key.properties 文件或使用示例文件: android/key.properties.example"
    fi
}

# 构建 Android App Bundle
build_android_aab() {
    print_info "开始构建 Android App Bundle (AAB)..."
    
    if [ -f "android/key.properties" ]; then
        flutter build appbundle --release
        cp "build/app/outputs/bundle/release/app-release.aab" "$OUTPUT_DIR/${PROJECT_NAME}-release.aab"
        print_success "Android App Bundle 已生成: $OUTPUT_DIR/${PROJECT_NAME}-release.aab"
    else
        print_warning "未找到 android/key.properties 文件，跳过 AAB 构建"
    fi
}

# 构建 iOS 应用
build_ios() {
    print_info "开始构建 iOS 应用..."
    
    # 检查是否在 macOS 上
    if [[ "$OSTYPE" != "darwin"* ]]; then
        print_warning "iOS 构建需要在 macOS 系统上运行，跳过 iOS 构建"
        return
    fi
    
    # 检查 Xcode 是否安装
    if ! command -v xcodebuild &> /dev/null; then
        print_warning "Xcode 未安装，跳过 iOS 构建"
        return
    fi
    
    # 构建 iOS
    flutter build ios --release --no-codesign
    
    print_info "iOS 应用已构建完成"
    print_warning "注意: iOS 应用需要代码签名才能在真机上运行"
    print_info "构建产物位于: ios/Runner.xcworkspace"
}

# 构建 macOS 应用
build_macos() {
    print_info "开始构建 macOS 应用..."
    
    # 检查是否在 macOS 上
    if [[ "$OSTYPE" != "darwin"* ]]; then
        print_warning "macOS 构建需要在 macOS 系统上运行，跳过 macOS 构建"
        return
    fi
    
    # 构建 macOS
    flutter build macos --release
    
    # 复制到输出目录
    MACOS_APP="build/macos/Build/Products/Release/paw.app"
    if [ -d "$MACOS_APP" ]; then
        # 创建压缩包
        tar -czf "$OUTPUT_DIR/${PROJECT_NAME}-macos.tar.gz" -C "build/macos/Build/Products/Release" "paw.app"
        print_success "macOS 应用已生成: $OUTPUT_DIR/${PROJECT_NAME}-macos.tar.gz"
    else
        print_warning "macOS 应用构建失败或产物未找到"
    fi
}

# 构建 Web 应用
build_web() {
    print_info "开始构建 Web 应用..."
    
    flutter build web --release
    
    # 复制到输出目录
    WEB_DIR="build/web"
    if [ -d "$WEB_DIR" ]; then
        # 创建压缩包
        tar -czf "$OUTPUT_DIR/${PROJECT_NAME}-web.tar.gz" -C "build" "web"
        print_success "Web 应用已生成: $OUTPUT_DIR/${PROJECT_NAME}-web.tar.gz"
        
        # 也复制未压缩的版本
        cp -r "$WEB_DIR" "$OUTPUT_DIR/web"
        print_info "Web 应用目录: $OUTPUT_DIR/web"
    else
        print_warning "Web 应用构建失败或产物未找到"
    fi
}

# 构建 Windows 应用
build_windows() {
    print_info "开始构建 Windows 应用..."
    
    # 检查是否在 Windows 或支持 Windows 构建的环境
    if [[ "$OSTYPE" != "msys"* ]] && [[ "$OSTYPE" != "cygwin"* ]] && [[ "$OSTYPE" != "win"* ]]; then
        # 在非 Windows 系统上，检查是否安装了 Flutter 的 Windows 构建支持
        if ! flutter config --enable-windows-desktop 2>/dev/null | grep -q "enabled"; then
            print_warning "Windows 桌面构建未启用，跳过 Windows 构建"
            print_info "运行 'flutter config --enable-windows-desktop' 启用 Windows 构建支持"
            return
        fi
    fi
    
    flutter build windows --release
    
    # 复制到输出目录
    WINDOWS_DIR="build/windows/runner/Release"
    if [ -d "$WINDOWS_DIR" ]; then
        # 创建压缩包
        tar -czf "$OUTPUT_DIR/${PROJECT_NAME}-windows.tar.gz" -C "build/windows/runner" "Release"
        print_success "Windows 应用已生成: $OUTPUT_DIR/${PROJECT_NAME}-windows.tar.gz"
    else
        print_warning "Windows 应用构建失败或产物未找到"
    fi
}

# 生成构建报告
generate_report() {
    print_info "生成构建报告..."
    
    REPORT_FILE="$OUTPUT_DIR/build-report-$(date +%Y%m%d-%H%M%S).txt"
    
    cat > "$REPORT_FILE" << EOF
AI Agent Hub 构建报告
生成时间: $(date)
项目版本: $VERSION
Flutter 版本: $(flutter --version | head -1)

构建平台:
$(ls -la "$OUTPUT_DIR" | grep -v "^total" | awk '{print $9}')

构建详情:
EOF
    
    # 添加文件详情
    ls -lh "$OUTPUT_DIR" >> "$REPORT_FILE"
    
    print_success "构建报告已生成: $REPORT_FILE"
}

# 主函数
main() {
    print_info "========================================"
    print_info "  AI Agent Hub - 多平台构建脚本"
    print_info "========================================"
    
    # 检查必要命令
    check_command flutter
    check_command tar
    check_command date
    
    # 检查 Flutter 环境
    check_flutter
    
    # 准备构建环境
    prepare_build
    
    # 构建各个平台
    print_info "开始构建各个平台..."
    
    # Android
    build_android_apk
    build_android_aab
    
    # iOS
    build_ios
    
    # macOS
    build_macos
    
    # Web
    build_web
    
    # Windows
    build_windows
    
    # 生成报告
    generate_report
    
    print_info "========================================"
    print_success "构建完成！"
    print_info "所有构建产物保存在: $OUTPUT_DIR/"
    print_info "构建报告: $OUTPUT_DIR/build-report-*.txt"
    print_info "========================================"
    
    # 显示构建结果
    echo ""
    print_info "构建结果:"
    ls -lh "$OUTPUT_DIR"
}

# 运行主函数
main "$@"