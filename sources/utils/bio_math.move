/// # 身份信用数学库 (Bio Math Utils)
///
/// 封装了 Protocol 75 信用系统中所有的纯数学计算逻辑。
/// 包括：
/// - 分段线性成本插值
/// - 能量积分计算
/// - 分数衰减计算
///
/// ## 为什么选择链上计算？(Why On-chain?)
/// 1. **信任源 (Root of Trust)**: 所有的计算规则公开透明且不可篡改。相比于预言机 (Oracle) 方案，用户不需要通过信任项目方的服务器来确信分数的公正性。
/// 2. **数据原子性 (Atomicity)**: 分数更新与打卡行为在同一笔交易内原子完成，避免了链下计算带来的异步延迟和状态不一致风险。
/// 3. **透明可审计 (Auditability)**: 社区可以随时验证算法的公平性，确保“越难越赚”的机制不被黑箱操作。
/// 4. **Gas 效率 (Efficiency)**: 本模块经过高度优化的整数运算 (Integer Math) 消耗的计算资源极低。相比于在链上验证复杂的密码学签名 (Signature Verification) 所需的昂贵 Gas，直接在链上计算数学公式反而更加经济高效。
///
/// 核心思想：输入状态 + 配置 -> 输出新状态 (Pure Functions)
module protocol_75::bio_math {
    friend protocol_75::bio_credit;

    // 参数结构定义 (Parameter Structs) ---------------------------------

    /// 能量曲线参数 (Curve Parameters)
    /// 用于封装传递给数学库的配置
    struct EnergyCurveParams has copy, drop, store {
        min_score: u64,
        max_score: u64,
        threshold_repair: u64,
        threshold_elite: u64,
        cost_repair_start: u64,
        cost_repair_end: u64,
        cost_accum_end: u64,
        cost_elite_end: u64
    }

    /// 构造曲线参数
    public fun new_curve_params(
        min_score: u64,
        max_score: u64,
        threshold_repair: u64,
        threshold_elite: u64,
        cost_repair_start: u64,
        cost_repair_end: u64,
        cost_accum_end: u64,
        cost_elite_end: u64
    ): EnergyCurveParams {
        EnergyCurveParams {
            min_score,
            max_score,
            threshold_repair,
            threshold_elite,
            cost_repair_start,
            cost_repair_end,
            cost_accum_end,
            cost_elite_end
        }
    }

    // 友元接口 (Friend Only) -------------------------------------------

    /// 计算当前分数下的瞬时能量成本 (Calculate Cost At)
    ///
    /// @param score: 当前分数
    /// @param params: 曲线参数
    /// @return 瞬时能量成本
    public(friend) fun calculate_cost_at(
        score: u64, params: &EnergyCurveParams
    ): u64 {
        // 区间1. 修复期 35 - 50
        if (score <= params.threshold_repair) {
            // 在此区间内，Cost 从 cost_repair_start 线性增加到 cost_repair_end
            linear_interpolate(
                score,
                params.min_score,
                params.threshold_repair,
                params.cost_repair_start,
                params.cost_repair_end
            )
        }
        // 区间2. 积累期 50 - 75
        else if (score <= params.threshold_elite) {
            // 在此区间内，Cost 从 cost_repair_end 线性增加到 cost_accum_end
            linear_interpolate(
                score,
                params.threshold_repair,
                params.threshold_elite,
                params.cost_repair_end,
                params.cost_accum_end
            )
        }
        // 区间3. 精英期 75 - 95
        else if (score <= params.max_score) {
            // 在此区间内，Cost 从 cost_accum_end 激增到 cost_elite_end
            linear_interpolate(
                score,
                params.threshold_elite,
                params.max_score,
                params.cost_accum_end,
                params.cost_elite_end
            )
        }
        // 避免报错，分数大于 95，直接返回最大成本
        else {
            params.cost_elite_end
        }
    }

    /// 积分计算加分 (Integrate Energy To Score)
    ///
    /// @param start_score: 起始分数
    /// @param energy: 能量
    /// @param params: 曲线参数
    /// @param decimals: 精度
    /// @return 加分后的分数
    public(friend) fun integrate_energy_to_score(
        start_score: u64,
        energy: u64,
        params: &EnergyCurveParams,
        decimals: u64
    ): u64 {
        let current_score = start_score;
        let remaining_energy = energy;

        // 1. 尝试通过 区间1 (修复期)
        if (current_score < params.threshold_repair && remaining_energy > 0) {
            let (new_score, used_energy) =
                solve_segment_integral(
                    current_score,
                    params.threshold_repair,
                    params.cost_repair_start,
                    params.cost_repair_end,
                    remaining_energy,
                    params.min_score,
                    params.threshold_repair,
                    decimals
                );
            current_score = new_score;
            remaining_energy -= used_energy;
        };
        // 2. 尝试通过 区间2 (积累期)
        if (current_score >= params.threshold_repair
            && current_score < params.threshold_elite
            && remaining_energy > 0) {
            let (new_score, used_energy) =
                solve_segment_integral(
                    current_score,
                    params.threshold_elite,
                    params.cost_repair_end,
                    params.cost_accum_end,
                    remaining_energy,
                    params.threshold_repair,
                    params.threshold_elite,
                    decimals
                );
            current_score = new_score;
            remaining_energy -= used_energy;
        };
        // 3. 尝试通过 区间3 (精英期)
        if (current_score >= params.threshold_elite && remaining_energy > 0) {
            let (new_score, used_energy) =
                solve_segment_integral(
                    current_score,
                    params.max_score,
                    params.cost_accum_end,
                    params.cost_elite_end,
                    remaining_energy,
                    params.threshold_elite,
                    params.max_score,
                    decimals
                );
            current_score = new_score;
            // 忽略剩余能量，因为已达上限或能量耗尽
            _ = used_energy;
        };

        current_score
    }

    /// 计算衰减后的分数 (Calculate Decayed Score)
    ///
    /// @param current_score: 当前分数
    /// @param last_update_time: 上次更新时间
    /// @param now: 当前时间
    /// @param params: 曲线参数
    /// @param grace_period: 豁免期
    /// @param energy_decay_base: 衰减基数
    /// @param decimals: 精度
    /// @return 衰减后的分数
    public(friend) fun calculate_decayed_score(
        current_score: u64,
        last_update_time: u64,
        now: u64,
        params: &EnergyCurveParams,
        grace_period: u64,
        energy_decay_base: u64,
        decimals: u64
    ): u64 {
        // 1. 检查是否在宽限期(豁免期)内
        if (now <= last_update_time + grace_period) {
            return current_score
        };

        // 2. 计算已过期的天数 (不包含宽限期)
        let decay_duration = (now - last_update_time) - grace_period;
        let days_passed = decay_duration / 86400; // 86400s = 1 day

        // 3. 执行衰减计算
        if (days_passed > 0) {
            // A. 获取当前分数的“瞬时阻力/成本”
            //    分数越高，Cost 越高，意味着在同样的基数下，衰减量越大（高分难守）。
            let current_cost = calculate_cost_at(current_score, params);

            // B. 计算总的基础衰减能量 (天数 * 每天的基础能量)
            let total_decay_base = days_passed * energy_decay_base;

            // C. 放大衰减量： 总能量 * Cost / Scaling
            //    Example: 10天 * 500k * Cost(3.0) = 5M * 3.0 = 15M Score Loss
            let total_decay_score = (total_decay_base * current_cost) / decimals;

            // D. 应用扣除，确保不低于最低分
            if (current_score > params.min_score + total_decay_score) {
                current_score - total_decay_score
            } else {
                params.min_score
            }
        }
        // 避免报错
        else {
            current_score
        }
    }

    // 私有方法 (Private Methods) ---------------------------------------

    /// 线性插值 (Linear Interpolation)
    /// 公式: y = y1 + (x - x1) * (y2 - y1) / (x2 - x1)
    ///
    /// @param x: 当前值
    /// @param x1: 起始值
    /// @param x2: 结束值
    /// @param y1: 起始值对应的y值
    /// @param y2: 结束值对应的y值
    /// @return 线性插值后的y值
    fun linear_interpolate(x: u64, x1: u64, x2: u64, y1: u64, y2: u64): u64 {
        if (x2 <= x1) return y1;
        if (x >= x2) return y2;

        let delta_x = x - x1;
        let range_x = x2 - x1;
        let range_y = y2 - y1;

        y1 + (delta_x * range_y) / range_x
    }

    /// 求解单段积分 (Solve Segment Integral)
    ///
    /// 核心逻辑：计算在该成本区间内，给定的能量能让分数增加多少。
    /// 本函数采用“梯形面积法”结合“两步逼近法”来求解近似值，避免复杂的开方运算。
    ///
    /// @param start_s: 起始分数
    /// @param max_s: 本段终点分数
    /// @param cost_start: 起始分数对应的能量成本
    /// @param cost_end: 终点分数对应的能量成本
    /// @param available_energy: 用户拥有的可用能量
    /// @param seg_min: 该段定义的最小分数
    /// @param seg_max: 该段定义的最大分数
    /// @param decimals: 精度
    /// @return (新分数, 实际消耗的能量)
    fun solve_segment_integral(
        start_s: u64,
        max_s: u64,
        cost_start: u64,
        cost_end: u64,
        available_energy: u64,
        seg_min: u64,
        seg_max: u64,
        decimals: u64
    ): (u64, u64) {
        // 0. 如果起点已经超过终点，无法在此区间移动
        if (start_s >= max_s) return (start_s, 0);

        // 1. 计算起点的瞬时成本 Cost(start)
        let cost_at_start =
            linear_interpolate(start_s, seg_min, seg_max, cost_start, cost_end);
        let cost_at_max = cost_end;

        // 2. 试算：如果跑完整个区间，需要多少能量？
        //    使用梯形面积公式：Area = (上底 + 下底) * 高 / 2
        //    Full Energy = (Cost_start + Cost_end) * Dist / 2
        let avg_cost = (cost_at_start + cost_at_max) / 2;
        let dist = max_s - start_s;
        let full_segment_energy = (avg_cost * dist) / decimals;

        // 3. 判断能量是否足够跑完本段 (Full Segment Check)
        if (available_energy >= full_segment_energy) {
            // A. 能量充足，直接到达本段终点，消耗 full_segment_energy
            return (max_s, full_segment_energy)
        } else {
            // B. 能量不足，将在中途停下。我们需要求解 target_s。
            //    Energy ~= Cost * dx  =>  dx ~= Energy / Cost

            // [Step 1] 一阶近似 (First-order Approximation)
            // 假设 Cost 不变，等于起点的 Cost。
            // dx_est = Energy / Cost_start
            let dx_est = (available_energy * decimals) / cost_at_start;
            let target_s = start_s + dx_est;

            // Clamp (防止估算过大超出本段)
            if (target_s > max_s) {
                target_s = max_s;
            };

            // [Step 2] 二阶修正 (Trapzoidal Correction)
            // 既然知道了大概落点 target_s，计算该点的 Cost_mid
            let cost_mid =
                linear_interpolate(
                    target_s,
                    seg_min,
                    seg_max,
                    cost_start,
                    cost_end
                );
            //取起点和中点的平均阻力
            let avg_cost_est = (cost_at_start + cost_mid) / 2;

            // 重新计算距离：Dist = Energy / Avg_Cost
            let dx_refined = (available_energy * decimals) / avg_cost_est;

            // 得到最终落点
            let final_s = start_s + dx_refined;
            if (final_s > max_s) {
                final_s = max_s;
            };

            // 返回最终落点
            // (注：为简化逻辑，这里假设耗光了所有 available_energy，尽管可能有微小误差，但在积分逻辑链中是安全的)
            (final_s, available_energy)
        }
    }
}

