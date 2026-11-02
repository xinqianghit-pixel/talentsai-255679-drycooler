# 干冷器场站回风掺混后的有效排热能力核算

## 背景

数据中心屋顶/场站布置的闭式干冷器（干式冷却器，sensible-only）在夏日偏南风工况下，排风羽流会被吹回进风面。运维侧有一份脚本，用来根据 BMS 读数估算当前可排热能力，并与铭牌设计点对照。

脚本能跑通，也输出合法 JSON，但对不上现场热平衡抽检。工程侧反馈至少有这些口径问题：

1. 进风侧不能直接拿场站气象站的环境干球；需要按回风掺混比例把排风温度掺进去，得到有效进风干球；
2. 干冷器是显热设备，湿球读数即便存在也不能拿来当进风基准；
3. BMS 里缓存的 `bms_duty_kw` 可能滞后，不能代替由乙二醇侧流量与温差核算的真实热负荷；可用排热能力应按“有效进风 + 铭牌设计逼近度”推，而不是盲信缓存负荷。

## 运行方式

- 代码：`/app/dry_cooler_cap.py`
- 工况：`/app/yard_sensors.json`
- 铭牌：`/app/nameplate.json`

```bash
python3 /app/dry_cooler_cap.py
```

## 验收口径

请按干冷器场站工程常识修正脚本：

- 有效进风干球：\(T_{air,eff} = (1-r)\,T_{amb} + r\,T_{disch}\)，其中 `r` 为工况中的回风掺混比例 `recirc_ratio`（0~1）；
- 忽略湿球；不要用 `twb_c`；
- 设计逼近度取铭牌 `design_approach_k`（流体出口相对设计进风的温差口径）；当前可排热能力：
  \[
  Q_{avail} = \dot m\,c_p\,\big(T_{fluid,in} - T_{air,eff} - A_{des}\big)
  \]
  其中 \(\dot m\)、\(c_p\)、\(T_{fluid,in}\) 来自工况，\(A_{des}\) 来自铭牌；
- 乙二醇侧实测热负荷仅作核对参考，不得用 `bms_duty_kw` 充当 `q_avail_kw`；
- 必要字段：工况中的 `recirc_ratio`、`tamb_c`、`tdisch_c`、`fluid_in_c`、`glycol_kg_s`、`cp_j_per_kg_k`，以及铭牌中的 `design_approach_k`。这些字段须为有限的 JSON number，布尔值、数字字符串与 `null` 均不作为数值接受；缺少字段时须报错，不得以默认值代替；
- `recirc_ratio` 必须在 \([0,1]\)；有效温差必须严格为正；`glycol_kg_s` 与 `cp_j_per_kg_k` 必须为正有限数；缺少必要字段、非有限数值或上述越界条件须非零退出，并向 stderr 给出错误说明；超时视为失败；
- `twb_c`、`bms_duty_kw`、`fluid_out_c` 等干扰字段不得参与可用排热计算；输入变化时输出必须随之变化。

## 期望输出

向 stdout **只打印一行** JSON（相对误差允许 0.1%；数值须为有限 JSON number，禁止 `NaN`/`Infinity`）：

```json
{"t_air_eff_c": <number>, "q_avail_kw": <number>}
```

- `t_air_eff_c`：保留 2 位小数
- `q_avail_kw`：保留 2 位小数（千瓦）

禁止写死某一组工况答案。

## 约束

- 保持脚本整体结构，只修正进风掺混、湿球误用与负荷口径相关错误
- 标准库即可
