## 一、项目简介

本项目基于 QEMU 提供的用户模式模拟环境，用于在x86主机上运行不同架构的Linux应用程序。通过集成musl交叉工具链，支持全静态链接，实现跨平台开发和测试。

## 二、musl简介

**musl**（发音同英文 "mussel"，即"贻贝"）是一个基于 **MIT 许可证** 的标准 C 库实现，面向 Linux 系统调用 API，适用于广泛的部署环境。

musl 天然适合做 **全静态链接**：编出的二进制自包含、不依赖目标架构根文件系统，可直接在 `qemu-user` 下运行，非常适合内核 / 嵌入式开发中构建静态用户态测试程序。本镜像通过预编译 musl 交叉工具链（`aarch64-linux-musl-gcc`、`riscv64-linux-musl-gcc`）获得这一便利。

### GitHub 仓库与下载地址

| 项目 | 地址 |
|------|------|
| 官网 | https://musl.libc.org/ |
| 官方源码仓库（自托管 git） | https://git.musl-libc.org/cgit/musl |
| GitHub 源码镜像 | https://github.com/kraj/musl |
| 预编译工具链站 musl.cc | https://musl.cc/ |
| GitHub 工具链镜像（本镜像所用下载源） | https://github.com/musl-cc/musl.cc |
| 工具链下载（GitHub Releases） | https://github.com/musl-cc/musl.cc/releases |
