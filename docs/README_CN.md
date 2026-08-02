<div align="center">
<h1 align="center">
<img src="images/app_icon.png" width="40"> OTP令牌
</h1>

![GitHub License](https://img.shields.io/github/license/OHOTP/ohtotptoken) ![GitHub Release](https://img.shields.io/github/v/release/OHOTP/ohtotptoken) ![GitHub Actions Workflow Status](https://img.shields.io/github/actions/workflow/status/OHOTP/ohtotptoken/build.yaml) ![QQ Group](https://img.shields.io/badge/QQ-1060812974-red)


</div>

原生鸿蒙开源OTP二步验证应用。

## 功能

- [x] 支持TOTP令牌
- [x] 支持HOTP令牌
- [x] 支持Steam令牌, [从Steam导入令牌](https://github.com/stratumauth/app/wiki/Importing-from-Steam)
- [x] 支持Forti令牌
- [x] 设置界面
- [x] 鸿蒙 Asset Store Kit（TEE 硬件级密钥保护）
- [x] 华为云盘备份与恢复（端到端加密）
- [x] 基于 BackupExtensionAbility 的换机迁移
- [x] 防窥保护（DLP）
- [x] 桌面卡片（TOTP & HOTP）

---
<b>手机</b>
<p float="left">
  <img height="400px" alt="phone1" src="../screenshot/phone1.jpg" />
  <img height="400px" alt="phone2" src="../screenshot/phone2.png" />
  <img height="400px" alt="phone3" src="../screenshot/phone3.jpg" />
  <img height="400px" alt="phone4" src="../screenshot/phone4.jpg" />
</p>
<b>PC</b>
<p float="left">
  <img height="300px" alt="pc1" src="../screenshot/pc1.jpg" />
  <img height="300px" alt="pc2" src="../screenshot/pc2.jpg" />
  <img height="300px" alt="pc3" src="../screenshot/pc3.png" />
  <img height="300px" alt="pc4" src="../screenshot/pc4.png" />
</p>

---

## 参考项目
- [paolostivanin/libcotp](https://github.com/paolostivanin/libcotp)
- [Netthaw/TOTP-MCU](https://github.com/Netthaw/TOTP-MCU)
- [ss23/fortitoken-mobile-registration](https://github.com/ss23/fortitoken-mobile-registration)
- [andOTP/andOTP](https://github.com/andOTP/andOTP): 图标包
- [iamhyc/Aigis](https://github.com/iamhyc/Aigis)
- [nanopb/nanopb](https://github.com/nanopb/nanopb): 用于 Google 身份验证器迁移的`protobuf`库

## 贡献

欢迎参与本项目！提交 Pull Request 前，请先阅读[贡献指南](../CONTRIBUTING.md)。

> ⚠️ **Pull Request 请提交到 [`dev`](https://github.com/OHOTP/ohtotptoken/tree/dev) 分支**，`main` 仅用于发布，且与自动发布 CI 绑定。