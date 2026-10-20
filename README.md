# FPGA Offload GC Coprocessor（FOGC²）

[![Platform](https://img.shields.io/badge/Platform-Xilinx%20Zynq--7000%20XC7Z100-blue)](#platform)
[![RTL](https://img.shields.io/badge/RTL-Verilog%202001-green)](#rtl)
[![Vivado](https://img.shields.io/badge/Vivado-2026.1-orange)](#quick-start)
[![License](https://img.shields.io/badge/License-MIT-yellow)](#license)
[![CI](https://github.com/HiEq/FPGA-Offload-GC-Coprocessor/actions/workflows/lint.yml/badge.svg)](https://github.com/HiEq/FPGA-Offload-GC-Coprocessor/actions/workflows/lint.yml)

> `CI` 只检查 shell/Python/PowerShell 语法、`gcc -fsyntax-only`、`iverilog` 的 RTL parse
> 与 `SHA256SUMS`；**不进行 RTL 功能仿真或上板**。功能证据见「仿真回归」「板级测试」与 `tools/logs/`。

Contents: [架构](#架构概览) · [平台](#platform) · [快速开始](#quick-start) ·
[寄存器](#register-map) · [对象图格式](#object-graph-ddr-format) · [版本对比](#版本对比历史数据) ·
[仿真回归](#仿真回归) · [中断](#中断链路) · [对优化 C 的参考对比](#对优化-c-的参考对比) ·
[发布与上板](#下载启动镜像release) · [测试命令](#板上测试命令速查)
