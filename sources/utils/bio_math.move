/// # 身份信用数学库 (Bio Math Utils)
///
/// 封装了 Protocol 75 信用系统中所有的纯数学计算逻辑。
/// 包括：
/// - 分段线性成本插值
/// - 能量积分计算
/// - 分数衰减计算
///
/// 核心思想：输入状态 + 配置 -> 输出新状态 (Pure Functions)
module protocol_75::bio_math {
    friend protocol_75::bio_credit;

    // 常量定义 (复制自 bio_credit 以保持独立性，或通过参数传入)
    const SCALING_FACTOR: u64 = 1_000_000;
    const CREDIT_MIN: u64 = 35_000_000;
    const CREDIT_MAX: u64 = 95_000_000;

    // 能量参数 (Base Energy) - 用于计算衰减和默认惩罚
    const DECAY_BASE_ENERGY: u64 = 500_000;

    /// 能量曲线参数 (Energy Curve Parameters)
    /// 对应 BioCreditConfig 中的数值部分
    struct EnergyCurveParams has copy, drop, store {
        threshold_repair: u64,
        threshold_elite: u64,
        cost_repair_start: u64,
        cost_repair_end: u64,
        cost_accum_end: u64,
        cost_elite_end: u64
    }

    // 友元接口 (Friend Only) -------------------------------------------

    /// 构造曲线参数 (New Curve Params)
    ///
    /// @param threshold_repair: 修复期阈值
    /// @param threshold_elite: 精英期阈值
    /// @param cost_repair_start: 修复期起始成本
    /// @param cost_repair_end: 修复期结束成本
    /// @param cost_accum_end: 积累期结束成本
    /// @param cost_elite_end: 精英期结束成本
    /// @return 能量曲线参数
    public fun new_curve_params(
        threshold_repair: u64,
        threshold_elite: u64,
        cost_repair_start: u64,
        cost_repair_end: u64,
        cost_accum_end: u64,
        cost_elite_end: u64
    ): EnergyCurveParams {
        EnergyCurveParams {
            threshold_repair,
            threshold_elite,
            cost_repair_start,
            cost_repair_end,
            cost_accum_end,
            cost_elite_end
        }
    }

    /// 计算当前分数下的瞬时能量成本 (Calculate Cost At)
    ///
    /// @param score: 当前分数
    /// @param params: 能量曲线参数
    /// @return 瞬时能量成本
    public(friend) fun calculate_cost_at(
        score: u64, params: &EnergyCurveParams
    ): u64 {
        // 1. 判断分数落在哪个区间

        // 区间1. 修复期 35 - 50
        if (score <= params.threshold_repair) {
            // 在此区间内，Cost 从 cost_repair_start 线性增加到 cost_repair_end
            linear_interpolate(
                score,
                CREDIT_MIN,
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
        else {
            // 在此区间内，Cost 从 cost_accum_end 激增到 cost_elite_end
            linear_interpolate(
                score,
                params.threshold_elite,
                CREDIT_MAX,
                params.cost_accum_end,
                params.cost_elite_end
            )
        }
    }

    /// 积分计算加分 (Integrate Energy To Score)
    ///
    /// @param start_score: 起始分数
    /// @param energy: 能量
    /// @param params: 能量曲线参数
    /// @return 加分后的分数
    public fun integrate_energy_to_score(
        start_score: u64, energy: u64, params: &EnergyCurveParams
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
                    CREDIT_MIN,
                    params.threshold_repair
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
                    params.threshold_elite
                );
            current_score = new_score;
            remaining_energy -= used_energy;
        };

        // 3. 尝试通过 区间3 (精英期)
        if (current_score >= params.threshold_elite && remaining_energy > 0) {
            let (new_score, used_energy) =
                solve_segment_integral(
                    current_score,
                    CREDIT_MAX,
                    params.cost_accum_end,
                    params.cost_elite_end,
                    remaining_energy,
                    params.threshold_elite,
                    CREDIT_MAX
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
    /// @param grace_period: 宽限期
    /// @param params: 能量曲线参数
    /// @return 衰减后的分数
    public fun calculate_decayed_score(
        current_score: u64,
        last_update_time: u64,
        now: u64,
        grace_period: u64,
        params: &EnergyCurveParams
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
            let total_decay_base = days_passed * DECAY_BASE_ENERGY;

            // C. 放大衰减量： 总能量 * Cost / Scaling
            //    Example: 10天 * 500k * Cost(3.0) = 5M * 3.0 = 15M Score Loss
            let total_decay_score = (total_decay_base * current_cost) / SCALING_FACTOR;

            // D. 应用扣除，确保不低于最低分
            if (current_score > CREDIT_MIN + total_decay_score) {
                current_score - total_decay_score
            } else {
                CREDIT_MIN
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
    /// @return (新分数, 实际消耗的能量)
    fun solve_segment_integral(
        start_s: u64,
        max_s: u64,
        cost_start: u64,
        cost_end: u64,
        available_energy: u64,
        seg_min: u64,
        seg_max: u64
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
        let full_segment_energy = (avg_cost * dist) / SCALING_FACTOR;

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
            let dx_est = (available_energy * SCALING_FACTOR) / cost_at_start;
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
            let dx_refined = (available_energy * SCALING_FACTOR) / avg_cost_est;

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

