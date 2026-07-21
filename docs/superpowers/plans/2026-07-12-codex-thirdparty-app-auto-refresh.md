# Codex ThirdParty 每周更新执行记录

## 目标

用一个可独立测试的更新器安全刷新 Codex ThirdParty App，并由 Codex 自动化每周执行，不把 1.4GB 复制逻辑塞进 Raycast 启动路径。

## 完成标准

- [x] 更新器支持只读检查和安全更新。
- [x] ThirdParty 运行中不替换、不强退。
- [x] 新副本保留独立 Bundle ID 和显示名称。
- [x] 复制、签名、竞态和安装后验证失败时保留或恢复旧版。
- [x] fixture 测试覆盖 10 个主流程与失败分支。
- [x] 真实环境能识别官方版本较新，并在 ThirdParty 运行时安全延后。
- [x] 用官方真实 App 完成临时端到端复制、身份重写和签名验证。
- [ ] 真实冷更新后，官方与 ThirdParty 版本一致且签名验证通过。
- [x] 每周日 10:00 的 Codex 自动化创建并复核。

## 边界

- 不自动更新官方 ChatGPT/Codex App。
- 不修改 `~/.codex-thirdparty` 中除版本标记和更新锁之外的数据。
- 不修改独立 Electron 用户数据目录。
- 不为了更新而终止正在运行的 ThirdParty。
- 不引入常驻 LaunchAgent。

## 命令

```bash
./codex-thirdparty-update.sh --check
./codex-thirdparty-update.sh --update
bash tests/codex-thirdparty-update.test.sh
```
