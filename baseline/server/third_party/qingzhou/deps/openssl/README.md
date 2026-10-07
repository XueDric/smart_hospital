# OpenSSL 3 的两个 DLL（**不随仓库提交**）

本目录预期放 `libcrypto-3-x64.dll` 与 `libssl-3-x64.dll`。它们是**运行时 `dlopen`** 用的，
不在 exe 的导入表里 —— 缺了**编译期没有任何警告**，运行时才报错（密码哈希、TLS 会失败）。

## 为什么不提交

它们是 6.5 MB 二进制，且与上游源码无关（由 OpenSSL / Git for Windows 提供）。
`server/third_party/qingzhou/` 只提交**源码与许可证材料**；
本目录的 `*.dll` 已写进 `.gitignore`，放进来**不会弄脏仓库**。

## 从哪来

`build.ps1` 按下面顺序找，**每一步都会打印用的是哪一份**（不会静默）：

1. **本目录**（放了就用）；
2. 命令行 `-OpenSslDir <目录>` —— 给了就**只用它**，不再回退；
3. **Git for Windows** 自带：`<Git>\mingw64\bin\`（本机实测 **3.5.7**，与原先从轻舟 `deps` 拷的版本一致；
   本项目本来就把 Git 的 `openssl.exe` 列为工具链依赖）。

三步都找不到时构建**报错退出**，并告诉你要放哪里。手动放一份：

```powershell
# 从 Git for Windows 拷（版本已核对：3.5.7）
Copy-Item "D:\Program Files\Git\mingw64\bin\libcrypto-3-x64.dll" .
Copy-Item "D:\Program Files\Git\mingw64\bin\libssl-3-x64.dll" .
```

## 部署时

`build.ps1` 会把它们拷进 `server\build\`；`build-package.ps1` 再从 `build\` 打进部署包 ——
**部署包必须带上这两个 DLL**（`dist\club-server\` 里少一个，密码哈希/TLS 就会在运行时 500）。
