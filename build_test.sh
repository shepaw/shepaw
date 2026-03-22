#!/bin/bash

# AI Agent Hub - 简化构建测试脚本
# 用于快速验证构建功能

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

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

# 检查命令
check_command() {
    if ! command -v "$1" &> /dev/null; then
        print_error "命令 '$1' 未找到"
        exit 1
    fi
}

# 快速构建测试
quick_build_test() {
    print_info "========================================"
    print_info "  Paw - 快速构建测试"
    print_info "========================================"
    
    # 检查环境
    check_command flutter
    
    print_info "Flutter 版本: $(flutter --version | head -1)"
    
    # 清理和准备
    print_info "清理构建目录..."
    rm -rf build
    
    print_info "获取依赖..."
    flutter pub get
    
    # 构建 Web（最快，无需签名）
    print_info "测试构建 Web 应用..."
    flutter build web --release 2>&1 | tail -20
    
    if [ -d "build/web" ]; then
        print_success "Web 构建成功！"
        print_info "Web 构建产物: build/web/"
        
        # 测试产物
        WEB_FILES=$(find build/web -name "*.html" -o -name "*.js" -o -name "*.css" | head -5)
        if [ -n "$WEB_FILES" ]; then
            print_success "Web 文件生成正常:"
            echo "$WEB_FILES"
        fi
    else
        print_error "Web 构建失败"
        exit 1
    fi
    
    # 构建 Android debug（无需签名）
    print_info "测试构建 Android debug APK..."
    flutter build apk --debug 2>&1 | tail -20
    
    if [ -f "build/app/outputs/flutter-apk/app-debug.apk" ]; then
        APK_SIZE=$(stat -f%z "build/app/outputs/flutter-apk/app-debug.apk" 2>/dev/null || stat -c%s "build/app/outputs/flutter-apk/app-debug.apk")
        print_success "Android debug APK 构建成功！"
        print_info "APK 大小: $((APK_SIZE/1024/1024)) MB"
    else
        print_warning "Android debug APK 构建可能失败"
    fi
    
    # 根据系统测试其他平台
    if [[ "$OSTYPE" == "darwin"* ]]; then
        # macOS 系统
        print_info "测试构建 macOS 应用..."
        flutter build macos 2>&1 | tail -20
        
        if [ -d "build/macos" ]; then
            print_success "macOS 构建成功！"
        fi
    else
        print_info "非 macOS 系统，跳过 iOS/macOS 构建测试"
    fi
    
    # 生成测试报告
    print_info "生成测试报告..."
    cat > build-test-report.txt << EOF
AI Agent Hub 构建测试报告
测试时间: $(date)
Flutter 版本: $(flutter --version | head -1)
系统: $(uname -a)

测试结果:
- Web 构建: $(if [ -d "build/web" ]; then echo "成功"; else echo "失败"; fi)
- Android debug APK: $(if [ -f "build/app/outputs/flutter-apk/app-debug.apk" ]; then echo "成功"; else echo "失败"; fi)
- macOS 构建: $(if [[ "$OSTYPE" == "darwin"* ]] && [ -d "build/macos" ]; then echo "成功"; else echo "跳过"; fi)

构建目录内容:
$(find build -type f -name "*.apk" -o -name "*.html" -o -name "*.js" 2>/dev/null | head -10)
EOF
    
    print_success "测试报告已生成: build-test-report.txt"
    
    print_info "========================================"
    print_success "快速构建测试完成！"
    print_info "详细构建测试请运行: ./build_all.sh"
    print_info "构建指南请查看: BUILD_GUIDE.md"
    print_info "========================================"
}

# 运行测试
quick_build_test "$@"