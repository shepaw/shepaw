# 资源文件目录

## 图片资源 (assets/images/)
请将应用所需的图片资源放在此目录，包括：
- logo.png - 应用Logo
- default_avatar.png - 默认头像
- empty_state.png - 空状态占位图

## 图标资源 (assets/icons/)
请将应用所需的图标资源放在此目录，包括：
- app_icon.png - 应用图标
- 其他自定义图标

## 字体资源 (fonts/)
请将字体文件放在此目录：
- Roboto-Regular.ttf
- Roboto-Bold.ttf

## 生成应用图标
使用 flutter_launcher_icons 包生成：
```bash
flutter pub add dev:flutter_launcher_icons
flutter pub run flutter_launcher_icons
```

## 生成启动画面
使用 flutter_native_splash 包生成：
```bash
flutter pub add dev:flutter_native_splash
flutter pub run flutter_native_splash:create
```
