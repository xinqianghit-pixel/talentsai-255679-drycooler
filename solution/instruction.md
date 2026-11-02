# 参考解说明

1. 解析 `units` 与方阵 `recirc_matrix`；校验唯一 id、机型、行和 < 1、非负矩阵元。
2. `t_eff[i] = (1-sum(row_i))*tamb + sum_j(row_i[j]*tdisch[j])`。
3. 用主动集/水填充把 `glycol_total_kg_s` 按 `valve_weight` 分配，触顶截断并再分配。
4. 每机 `q = min(m*cp*dT/1000, curve_interp(model))`；`q_site = sum(q)`。
5. 输出顺序与输入 units 一致；内部不提前 round；stdout 仅一行 `allow_nan=False` JSON。
