# Code Review — prometheus-node-exporter DEB 打包

## 概览

审查范围：19 个新文件（`.github/workflows/`、`node_exporter-deb/`、`LATEST_VERSION`）。

共发现 **12 个问题**，按严重程度排列。

---

## 🔴 会导致安装或运行失败

### 1. postinst: 首次安装会因目录不存在而失败

**文件:** `node_exporter-deb/debian/postinst:12`

`adduser --no-create-home` 创建了 prometheus 用户，但没有创建 `/var/lib/prometheus` 目录。紧接着：

```sh
chown prometheus:prometheus /var/lib/prometheus
```

目录不存在 → chown 报错 → `set -e` 导致 postinst 退出 → 包处于 half-configured 状态。

**怎么触发：** 全新系统上首次 `dpkg -i` 安装。

**修法：** chown 之前加 `mkdir -p /var/lib/prometheus`。

---

### 2. ExecReload SIGHUP 是无效操作

**文件:** `node_exporter-deb/debian/service:10`

```ini
ExecReload=/bin/kill -HUP $MAINPID
```

node_exporter 没有 SIGHUP 信号处理逻辑。收到这个信号要么被忽略，要么进程直接被 kill。运维改完 `/etc/default/prometheus-node-exporter` 里的 `ARGS` 后跑 `systemctl reload`，表面上返回 success，实际上进程用的还是旧参数。

**怎么触发：** 任何一次 `systemctl reload prometheus-node-exporter`。

**修法：** 删除 `ExecReload` 行，或者换成 `/bin/true` 并加注释说明需要 `restart` 才能应用配置变更。

---

### 3. build.sh: 架构自动检测在依赖安装之前运行

**文件:** `node_exporter-deb/build.sh:14`

```bash
target_arch=$(dpkg-architecture -q DEB_HOST_ARCH 2>/dev/null || echo "amd64")
```

这行在脚本顶层、所有函数之前执行。此时 `dpkg-dev`（提供 `dpkg-architecture`）可能还没装。如果没装 → stderr 被 `2>/dev/null` 吞掉 → fallback 到 `amd64`。后面 `perform_safety_checks` 虽然会装 `dpkg-dev`，但 `target_arch` 已经锁死了。

**怎么触发：** 全新 arm64 Debian 机器上第一次运行（`dpkg-dev` 未安装时）。

**修法：** 把架构检测移到 `perform_safety_checks` 安装完依赖之后。

---

## 🟡 会导致静默异常

### 4. build.sh: `-l` 列出版本时网络错误被静默吞掉

**文件:** `node_exporter-deb/build.sh:343`

```bash
for func in "${execute_features[@]}"; do
    ($func)    # ← 子 shell！exit 只退出子 shell
done
[ ${#execute_features[@]} -gt 0 ] && exit 0
```

`print_available_versions` → `get_available_versions` → curl 失败 → `exit 7`。但函数在 `(...)` 子 shell 里运行，`exit 7` 只退出子 shell，主脚本继续走到 `exit 0`。

**怎么触发：** `./build.sh -l` 时没有网络。

**修法：** 把 `($func)` 改成 `$func`（不加括号），让函数在主 shell 运行。

---

### 5. build.sh: `-r` 参数未校验，可注入 sed 特殊字符

**文件:** `node_exporter-deb/build.sh:309`

```bash
local version_string="$pkg_version-$pkg_release"
sed -i "1s/(.*)/(${version_string})/" debian/changelog
```

`pkg_version` 已校验（必须匹配上游 release 列表）。但 `pkg_release` 来自 `-r` 参数，完全没校验。

- `./build.sh -r "1/debian"` → sed 报错（`/` 破坏了 `s///` 分隔符）
- `./build.sh -r "1\&bad"` → `&` 把匹配到的旧版本注入替换结果

**怎么触发：** 传了含 `/` 或 `&` 的 `-r` 值。

**修法：** 在 `validate_inputs` 中校验 `pkg_release` 只含 `[a-zA-Z0-9.~+-]`；或者用 `awk` 代替 `sed` 做替换。

---

### 6. build.sh: `rm -rf $build_root` 没有路径安全保护

**文件:** `node_exporter-deb/build.sh:249`

```bash
rm -rf "$build_root"
```

`-b` 可以传任意路径。假如用户传了 `/`、`/home` 或者路径里有空格导致的意外，就是灾难性删除。

**怎么触发：** 误操作或参数解析异常。

**修法：** 加检查——`build_root` 必须是 `current_dir` 的子目录，或者至少不是 `/` 之类的顶层路径，删除前验证路径非空且不存在符号链接指向外部。

---

## 🔵 设计/维护问题

### 7. logrotate 配置是死配置

**文件:** `node_exporter-deb/debian/logrotate`

```nginx
/var/log/prometheus/prometheus-node-exporter.log {
    weekly
    rotate 10
    ...
    missingok
}
```

systemd service 默认 `StandardOutput=journal`，日志直接进 journald。没有任何东西往 `/var/log/prometheus/prometheus-node-exporter.log` 写内容。`missingok` 让 logrotate 在文件不存在时不报错，所以每周都在空转。

**怎么影响：** 包依赖了一个不必要的 `logrotate`，装进了无用的配置文件。运维想看日志发现文件永远是空的。

**修法：** 二选一 —— 要么 service 加 `StandardOutput=file:/var/log/prometheus/prometheus-node-exporter.log`，要么删掉 logrotate 配置并从 Depends 移除 `logrotate`。

---

### 8. debian/docs: LICENSE 复制逻辑与引用不一致

**文件:** `node_exporter-deb/debian/docs:1` 和 `node_exporter-deb/build.sh:257`

`debian/docs` 无条件声明安装 `LICENSE`：
```
LICENSE
```

但 `build.sh` 只在文件存在时才复制：
```bash
if [ -f "$current_dir/../LICENSE" ]; then
    cp "$current_dir/../LICENSE" "$build_root/"
fi
```

**怎么触发：** sparse checkout 或 LICENSE 文件缺失时，`dh_installdocs` 找不到文件，构建失败。

**修法：** 要么把 LICENSE 提交到仓库里（不再依赖 build.sh 复制），要么让 `debian/docs` 也用条件化处理。

---

### 9. changelog 日期固化在模板里

**文件:** `node_exporter-deb/debian/changelog:5`

```
 -- prom_node_exporter ...  Tue, 16 Jun 2026 00:00:00 +0000
```

`update_changelog()` 只替换了第一行的版本号，trailer 日期永不变。dpkg 用 changelog 日期做同版本号的排序 tiebreaking——所有构建看起来都是同一天。

**怎么影响：** 同版本多次构建时，排序不确定。

**修法：** `sed` 替换时同时更新日期行，或者改用 `dch`（通过 `DEBIAN_FRONTEND=noninteractive` 避免交互）。

---

### 10. source/format 声明错误

**文件:** `node_exporter-deb/debian/source/format:1`

```
3.0 (native)
```

`native` 表示"这是 Debian 原生软件"。实际上这是给上游 node_exporter 打二进制包，应该用 `3.0 (quilt)`。

**怎么影响：** CI 里不影响，但如果要上传到 Debian 官方仓库会被拒。语义也不对。

**修法：** 改成 `3.0 (quilt)`。

---

### 11. check-version.yml: API 返回 null 时写字符串 "null" 到 LATEST_VERSION

**文件:** `.github/workflows/check-version.yml:21`

```yaml
latest=$(curl -sSf ... | jq -r .tag_name)
```

如果 GitHub API 返回 `{"tag_name": null}`（极端情况：仓库没有发布过 release），`jq -r` 输出字面字符串 `null`。这个值是非空的，会通过 `!= ''` 检查，写入 `LATEST_VERSION`。下游 `build.yml` 读出来 `null`，构建必然炸。

**怎么触发：** 上游仓库被删除或 API 异常返回 null。

**修法：** 加校验——`jq` 之后再检查是否为空或为字面量 `null`。

---

### 12. lintian 用 `|| true` 掩盖所有错误

**文件:** `.github/workflows/build.yml:48`

```yaml
lintian node_exporter-deb/prometheus-node-exporter_*.deb || true
```

`|| true` 让 warning 和 error 都绿色通过。应该至少让 error 级别报红。

**修法：** 检查 lintian 退出码——0 正常，1 只有 warning/tag 正常，2 是 error 应该报红。或者改用 `--fail-on-warnings` 等选项精确控制。

---

## ✅ 已核实正确

以下声称在审查中被验证为 **不成立**：

| 声称 | 核实结果 |
|------|---------|
| `debian/default` 不会被装进包 | **不成立** — debhelper 自动检测并安装了 `/etc/default/prometheus-node-exporter` |
| `build.yml` 中版本号可注入 | **不成立** — git tag 命名限制 + `validate_inputs` 校验组成了多层防护 |
| Release Draft 可能在部分架构失败时仍列出全部架构 | **不成立** — `needs: build` 要求所有 matrix job 成功，任一失败则 release job 被 skip |
