# 参考解说明

1. 用 `recirc_ratio` 将 `tamb_c` 与 `tdisch_c` 掺混得到有效进风干球，禁用 `twb_c`。
2. 乙二醇侧显热上限：`m*cp*(fluid_in - t_air_eff - design_approach_k)/1000`，单位 kW。
3. 读取铭牌 `capacity_curve`，按有效进风线性插值（端点夹取），得到铭牌能力。
4. 最终 `q_avail_kw = min(乙二醇显热上限, 曲线能力)`；不要用 `bms_duty_kw` / 单独 `design_capacity_kw`。
5. 校验：`r∈[0,1]`、必要字段存在、曲线点合法且横坐标严格递增、`m>0`、`cp>0`、全部有限、有效温差严格为正；失败时非零退出并写 stderr。
6. stdout 仅一行 `json.dumps(..., allow_nan=False)`。
