# Store / 上架发布清单

面向 App Store / Google Play / 桌面分发前的材料与合规核对。

## Apple（iOS / macOS）

- [x] `ios/Runner/PrivacyInfo.xcprivacy`（Required Reason API 声明；无 tracking）
- [x] `macos/Runner/PrivacyInfo.xcprivacy`
- [x] URL Scheme `shepaw://`（`Info.plist` → `CFBundleURLTypes`）
- [ ] App Privacy Questionnaire（与应用内隐私政策一致：本地优先；第三方 LLM / Channel 由用户配置）
- [ ] 截图素材（建议尺寸）：
  - iPhone 6.7"：1290×2796
  - iPhone 6.5"：1284×2778
  - iPad 12.9"：2048×2732
  - macOS：1280×800 或 1440×900
- [ ] 应用图标：已由 `flutter_launcher_icons` 生成；上架前用真机核对圆角裁切
- [ ] 审核备注：说明本地优先、无强制账号、Agent / Hub 为用户自托管

## Google Play（Android）

- [x] Deep link：`AndroidManifest` 注册 `shepaw` scheme
- [ ] Data safety 表单（与隐私政策对齐：无出售数据；可选第三方端点由用户配置）
- [ ] 功能图 / 截图：手机 + 平板（如声明）
- [ ] 签名：使用**轮换后**的 release keystore（见 `BUILD_GUIDE.md` / `data/README.md`）
- [ ] targetSdk 满足商店最低要求（随 AGP / Flutter 升级）

## 素材目录建议（未进仓）

本地准备、勿提交密钥：

```
store_assets/          # 可加入 .gitignore
  ios/
  android/
  macos/
  copy/
    short_description_en.txt
    short_description_zh.txt
    full_description_en.txt
    full_description_zh.txt
```

## 文案要点

- 品牌：ShePaw / 惜宝
- 一句话：本地优先的多 Agent 协作与对话中枢
- 勿声称「聊天库全盘加密」——当前 SQLite 默认明文；凭证走 Secure Storage（见应用内隐私政策）

## 相关文件

- 隐私政策：`lib/l10n/app_*.arb` → `privacy_content`
- 构建：`BUILD_GUIDE.md`
- 开发约定：`DEVELOPMENT.md`
