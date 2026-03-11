# 运行日志同步说明

## 目标

将单次运行日志追加同步到 `c:\Users\gzr\Desktop\code\logs\full.log`。

## 入口

- 脚本：`tools/sync_full_log.ps1`
- npm 命令：`npm run sync:full-log`

## 用法

默认模式会从设备拉取最新的 `run_*.log` 并追加到 `logs/full.log`：

```powershell
npm run sync:full-log
```

如果需要指定本地源文件：

```powershell
powershell -ExecutionPolicy Bypass -File .\tools\sync_full_log.ps1 -SourceFile "D:\temp\run_123.log"
```

如果需要从指定设备和目录拉取：

```powershell
powershell -ExecutionPolicy Bypass -File .\tools\sync_full_log.ps1 -PullFromDevice -DeviceSerial "192.168.1.100:8710" -DeviceLogDir "/data/storage/el2/base/files/logs"
```

## 参数

- `-SourceFile`：指定本地源日志文件路径；设置后默认不走设备拉取。
- `-PullFromDevice`：强制走设备拉取模式。
- `-DeviceSerial`：可选，指定设备序列号或 IP:端口。
- `-DeviceLogDir`：设备日志目录，默认 `/data/storage/el2/base/files/logs`。

## 结果

每次执行会在 `logs/full.log` 追加一个带时间戳和来源信息的新日志区块。
