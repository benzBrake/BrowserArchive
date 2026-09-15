# BrowserArchive

浏览器版本归档仓库，通过 GitHub Actions 定时抓取并提交版本数据。

## 定时任务约定

- 三个 workflow（`.github/workflows/whale.yml`、`brave.yml`、`vivaldi.yml`）每天北京时间 **01:00 和 13:00** 各运行一次（cron `0 17 * * *` 和 `0 5 * * *`，UTC）。
- 修改运行时间时，三个文件需保持一致，并以北京时间注释标明。
