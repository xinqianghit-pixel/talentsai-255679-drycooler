# 多机干冷器场站：交叉回风与泵—支路水力平衡下的可用排热

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
- `glycol_total_kg_s`：泵曲线零扬程流量尺度（kg/s），必须为正有限数
- `pump_shutoff_head_kpa`：泵关断扬程（kPa），必须为正有限数
- `cp_j_per_kg_k`：乙二醇比热（J/(kg·K)），必须为正有限数
- `air_cp_j_per_kg_k`：空气定压比热（J/(kg·K)），必须为正有限数
- `units`：长度 \(N\ge 2\) 的数组；每个单元对象含：
  - `id`：非空字符串，全局唯一
  - `tdisch_c`、`fluid_in_c`：有限数
  - `air_mass_flow_kg_s`：单机空气质量流量（kg/s），必须为正有限数
  - `valve_weight`：有限数且 \(\ge 0\)
  - `max_flow_kg_s`：正有限数
  - `model_id`：字符串，必须能在铭牌 `models` 中找到
- `recirc_matrix`：\(N\times N\) 方阵。`recirc_matrix[i][j]` 表示**单元 j 的排风进入单元 i 进风**的比例（有限且 \(\ge 0\)）。第 i 行元素之和必须**严格小于 1**（剩余份额来自环境干球）。

铭牌必要字段：

- `design_approach_k`：有限数，全站共用逼近度
- `models`：对象；每个机型至少含 `capacity_curve`（≥2 点）。每个点对象含有限数字段 `t_air_eff_c`、`q_cap_kw`，且 `t_air_eff_c` **严格递增**。

`twb_c`、`bms_duty_kw`、`fluid_out_c`、机型 `design_capacity_kw` 等为干扰字段，不得单独充当能力结果。

### 有效进风与羽流热平衡（隐式耦合）

对单元 i：

\[
t_{\mathrm{eff},i}=(1-\sum_j r_{ij})\,T_{\mathrm{amb}}+\sum_j r_{ij}\,T_{\mathrm{disch},j}
\]

其中 \(r_{ij}=\)`recirc_matrix[i][j]`。不要用湿球。输入 `tdisch_c` 只作为迭代初值；最终排风温度必须与本轮排热量自洽：

\[
T_{\mathrm{disch},i}=t_{\mathrm{eff},i}+\frac{1000q_{\mathrm{avail},i}}{\dot m_{\mathrm{air},i}c_{p,\mathrm{air}}}
\]

因此有效进风、单机能力与排风温度构成非线性固定点。按输入 `tdisch_c` 初始化，使用阻尼迭代：每轮先由旧排风温度同时计算全部 `t_eff` 与 `q_avail`，再令 `tdisch_new = 0.5*tdisch_target + 0.5*tdisch_old`。当所有单机新旧排风温度最大绝对差不超过 `1e-8 °C` 时收敛，最多 200 轮；超限须报错。最终输出使用收敛轮计算出的 `t_eff` 与 `q_avail`。

### 泵曲线—支路压降共同求根

`glycol_total_kg_s` 记为泵的零扬程流量尺度 $Q_0$，`pump_shutoff_head_kpa` 记为关断扬程 $H_0$。公共压头 $H$ 下，单机支路流量为：

\[ q_i(H)=\min\left(q_{i,\max},\;v_i\sqrt{H/K_i}\right) \]

其中 $v_i$ 为 `valve_weight`，$K_i$ 为 `branch_resistance_kpa_per_kg_s2`；零开度支路流量为 0。泵曲线为：

\[ H_p(Q)=H_0\left(1-(Q/Q_0)^2\right),\qquad Q=\sum_i q_i(H) \]

在闭区间 $[0,H_0]$ 求唯一公共压头根 $H=H_p(\sum_i q_i(H))$。使用二分法，压头区间宽度不超过 `1e-9 kPa` 时结束，最多 160 轮；根未被区间包围或未收敛须报错。内部计算不得提前四舍五入。阀限位通过 `min` 参与共同求根，不得把各支路独立求解，也不得继续使用按权重瓜分总流量的主动集算法。

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

- 保持脚本整体结构，只修正交叉回风、泵—支路水力求根、曲线插值与负荷口径相关错误
- 标准库即可


### ???????????????Shot C?

`recirc_matrix` ???????????????????????? `plume_calibration`??? 2 ??????????? `ambient_c`???? N ? `discharge_c` ???? N ? `observed_inlet_c`???? k??????? i???

\[x_{ki}=\sum_j r_{ij}(T^{cal}_{disch,kj}-T^{cal}_{amb,k}),\quad y_{ki}=T^{cal}_{in,ki}-T^{cal}_{amb,k}\]

????????????????????????????????????

\[g=\frac{\sum_{k,i}x_{ki}y_{ki}}{\sum_{k,i}x_{ki}^2}.\]

?????? `1e-12`???????????????????????????? `g * recirc_matrix`???????????? 1?????????????????????????????????????????????????????????????????? IEEE-754 ????? tie-break?
