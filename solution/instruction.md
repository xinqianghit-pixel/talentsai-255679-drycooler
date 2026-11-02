# 参考解说明

1. 用 `recirc_ratio` 将 `tamb_c` 与 `tdisch_c` 掺混得到有效进风干球，禁用 `twb_c`。
2. 可用排热：`m*cp*(fluid_in - t_air_eff - design_approach_k)/1000`，单位 kW。
3. 校验：`r∈[0,1]`、必要字段存在、`m>0`、`cp>0`、全部有限、有效温差严格为正；失败时非零退出并写 stderr。
4. stdout 仅一行 `json.dumps(..., allow_nan=False)`；不要使用 `bms_duty_kw`。
