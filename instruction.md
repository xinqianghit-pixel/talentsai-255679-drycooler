# 多机干冷器场站：交叉回风与共享乙二醇流量下的可用排热

## 背景

数据中心场站并列布置多台闭式干冷器（sensible-only）。偏南风时，各机排风羽流会交叉吹入邻机进风面；乙二醇侧则由站级总流量经阀门权重与单机上限做主动集分配。运维脚本能跑通并输出 JSON，但对不上热平衡抽检。

## 运行方式

- 代码：`/app/dry_cooler_cap.py`
- 工况：`/app/yard_sensors.json`
- 铭牌：`/app/nameplate.json`

```bash
python3 /app/dry_cooler_cap.py
```

## 验收口径

### 输入

工况必要字段：

- `tamb_c`：环境干球（°C）
- `glycol_total_kg_s`：站级乙二醇总质量流量（kg/s），必须为正有限数
- `cp_j_per_kg_k`：乙二醇比热（J/(kg·K)），必须为正有限数
- `units`：长度 \(N\ge 2\) 的数组；每个单元对象含：
  - `id`：非空字符串，全局唯一
  - `tdisch_c`、`fluid_in_c`：有限数
  - `valve_weight`：有限数且 \(\ge 0\)
  - `max_flow_kg_s`：正有限数
  - `model_id`：字符串，必须能在铭牌 `models` 中找到
- `recirc_matrix`：\(N\times N\) 方阵。`recirc_matrix[i][j]` 表示**单元 j 的排风进入单元 i 进风**的比例（有限且 \(\ge 0\)）。第 i 行元素之和必须**严格小于 1**（剩余份额来自环境干球）。

铭牌必要字段：

- `design_approach_k`：有限数，全站共用逼近度
- `models`：对象；每个机型至少含 `capacity_curve`（≥2 点）。每个点对象含有限数字段 `t_air_eff_c`、`q_cap_kw`，且 `t_air_eff_c` **严格递增**。

`twb_c`、`bms_duty_kw`、`fluid_out_c`、机型 `design_capacity_kw` 等为干扰字段，不得单独充当能力结果。

### 有效进风

对单元 i：

\[
t_{\mathrm{eff},i}=(1-\sum_j r_{ij})\,T_{\mathrm{amb}}+\sum_j r_{ij}\,T_{\mathrm{disch},j}
\]

其中 \(r_{ij}=\)`recirc_matrix[i][j]`。不要用湿球。

### 共享流量主动集分配

站级总流量 `glycol_total_kg_s` 按以下规则分配到各机 `flow_kg_s`（内部计算不要提前四舍五入）：

1. 初始剩余流量 = 站级总量；活跃集 = 所有 `valve_weight>0` 且 `max_flow_kg_s>0` 的单元。
2. 每一轮：按活跃单元的 `valve_weight` **正比**瓜分当前剩余流量。
3. 若某单元本轮份额会使其累计流量达到/超过 `max_flow_kg_s`：将该单元**截断到上限**，移出活跃集；把站级总量减去已分配总量得到新的剩余流量，进入下一轮。
4. 若本轮无人触顶：把本轮份额全部加给活跃单元，结束。
5. 若剩余耗尽或活跃集为空则结束。分配必须收敛；总分配不得超过站级总量，单机不得超过其上限。

零权重单元流量为 0。

### 单机能力与站级汇总

对单元 i：

- 乙二醇显热上限（kW）：`flow_i * cp * (fluid_in_i - t_eff_i - design_approach_k) / 1000`
- 有效温差必须严格为正，否则报错
- 曲线能力：取该机 `model_id` 对应 `capacity_curve`，按 `t_eff_i` **线性插值**；低于最左或高于最右时**夹取到端点**（不外推）
- `q_avail_i = min(显热上限, 曲线能力)`
- 站级 `q_site_kw = sum_i q_avail_i`

### 校验与输出

数值字段须为有限 JSON number（拒绝布尔、数字字符串、`null`、NaN/Inf）。缺字段、重复 `id`、未知机型、非方阵/行长错误、负矩阵元、行和 \(\ge 1\)、非正总流量/比热/上限、坏曲线等须非零退出并写 stderr。超时视为失败。

stdout **只打印一行** JSON（相对误差允许 0.1%；禁止 NaN/Inf）：

```json
{"q_site_kw": <number>, "units": [{"id": <str>, "t_air_eff_c": <number>, "flow_kg_s": <number>, "q_avail_kw": <number>}]}
```

- `units` 数组顺序必须与输入 `units` 一致
- 所有数值保留 2 位小数
- 禁止写死某一组工况答案

## 约束

- 保持脚本整体结构，只修正交叉回风、共享流量分配、曲线插值与负荷口径相关错误
- 标准库即可
