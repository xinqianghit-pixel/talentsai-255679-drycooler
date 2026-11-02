# 参考解说明

1. 用 `recirc_ratio` 将 `tamb_c` 与 `tdisch_c` 掺混得到有效进风干球，禁用 `twb_c`。
2. 可用排热：`m*cp*(fluid_in - t_air_eff - design_approach_k)/1000`，单位 kW。
3. 拒绝越界掺混比与非正有效温差；不要使用 `bms_duty_kw`。
