# CBizDocsManager

CBizDocsManager 是一套基于 Go 与 Flutter 开发的跨平台业务单据管理系统，正式支持 Android、Windows 和 Web。

当前已完成不依赖正式原型图的基础纵向闭环：后端认证、分组成员、细粒度权限和辅助字典 API，以及 Flutter 跨端认证、路由守卫、原生离线缓存、Outbox、成员与字典数据层。正式业务页面仍等待原型图后开发。

- [`backend/README.md`](backend/README.md)：Go API、本地 Docker 中间件、Web Cookie 安全约束及验证命令。
- [`client/README.md`](client/README.md)：Flutter 环境、跨平台地址差异、代码生成、运行和构建命令。
- [`docs/output/需求.md`](docs/output/需求.md)：当前产品需求基线。
- [`docs/output/技术设计.md`](docs/output/技术设计.md)：系统边界与技术设计。
- [`docs/update/`](docs/update/)：按任务记录的教学式变更说明。
