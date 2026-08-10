# Security Policy / 安全政策

## Supported Versions / 支持版本

Security fixes are provided for the latest published release only.
仅当前最新公开版本接收安全修复。

| Version | Supported |
| --- | --- |
| 1.5.x | Yes |
| Earlier versions | No |

## Reporting a Vulnerability / 报告漏洞

Please use the repository's **Security → Report a vulnerability** form to send a private report. Do not disclose an unpatched vulnerability in a public issue, discussion, or pull request.

请通过仓库 **Security → Report a vulnerability** 私密提交漏洞。请勿在公开 Issue、Discussion 或 Pull Request 中披露尚未修复的漏洞。

Include the affected version, macOS version, archive format, reproduction steps, expected and actual behavior, and a minimal sample archive when it is safe to share. Never include real passwords or confidential data.

请提供受影响版本、macOS 版本、压缩格式、复现步骤、预期及实际行为，并在安全的前提下附上最小样本压缩包。请勿提交真实密码或机密数据。

The maintainer will acknowledge a report as soon as practical, investigate it privately, and coordinate disclosure after a fix is available. Reports involving path traversal, link escapes, arbitrary file overwrite, command injection, credential exposure, or bundled-binary integrity receive priority.

维护者会尽快确认报告、进行私密调查，并在修复可用后协调披露。路径穿越、链接越界、任意文件覆盖、命令注入、凭据泄露及内置二进制完整性问题将优先处理。

## Security Boundary / 安全边界

Archives are untrusted input. The app performs preflight checks and staged extraction, but the bundled archive engine still parses attacker-controlled data in a local, non-sandboxed process. The public build uses an ad-hoc Hardened Runtime signature and is not Apple-notarized. See the README and release checksums before installing downloaded builds.

压缩包属于不可信输入。应用会执行预检和分阶段解压，但内置引擎仍会在本地、非沙箱进程中解析攻击者控制的数据。公开构建使用带 Hardened Runtime 的 ad-hoc 签名，未经 Apple 公证。安装下载版本前请查看 README 与发布校验和。
