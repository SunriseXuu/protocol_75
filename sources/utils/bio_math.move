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

    // 数值常量 (Constants) ---------------------------------------------

    /// 精度 (Decimals)
    const DECIMALS: u64 = 1_000_000;

    /// 最小信用分
    const CREDIT_MIN: u64 = 35_000_000;
    /// 初始信用分
    const CREDIT_INIT: u64 = 50_000_000;
    /// 精英信用分
    const CREDIT_ELITE: u64 = 75_000_000;
    /// 最大信用分
    const CREDIT_MAX: u64 = 95_000_000;

    /// 成本: 修复期起点 (1.0)
    const COST_REPAIR_START: u64 = 1_000_000;
    /// 成本: 修复期终点 (1.25)
    const COST_REPAIR_END: u64 = 1_250_000;
    /// 成本: 积累期终点 (3.0)
    const COST_ACCUM_END: u64 = 3_000_000;
    /// 成本: 精英期终点 (10.0)
    const COST_ELITE_END: u64 = 10_000_000;

    /// 能量放大系数
    /// 用于将任务难度系数 (Difficulty) 转换为链上能量值。
    /// 计算逻辑：
    /// - 设计为 50 -> 75 分 需要大约 6个月 (180天)
    /// - 计算出总能量需求: ~52.5M
    /// - 计算出每日能量需求: ~300k
    /// - 假设平均每日任务难度: 500
    /// - 所以放大系数 = 300,000 / 500 = 600
    const ENERGY_SCALING_FACTOR: u64 = 600;
    /// 能量衰减基数
    /// 计算逻辑：
    /// - 一日练，四日功，由于每日能量需求: ~300k
    /// - 所以设计为上述每日能量需求的 1/4 = 75,000
    const ENERGY_DECAY_BASE: u64 = 75_000;
    /// 衰减豁免期 (48小时)
    const DECAY_GRACE_PERIOD: u64 = 172800;

    // 友元接口 (Friend Only) -------------------------------------------

    /// 计算当前分数下的瞬时能量成本 (Calculate Cost At)
    ///
    /// @param score: 当前分数
    /// @return 瞬时能量成本
    public(friend) fun calculate_cost_at(score: u64): u64 {
        // 区间1. 修复期 35 - 50
        if (score <= CREDIT_INIT) {
            linear_interpolate(
                score,
                CREDIT_MIN,
                CREDIT_INIT,
                COST_REPAIR_START,
                COST_REPAIR_END
            )
        }
        // 区间2. 积累期 50 - 75
        else if (score <= CREDIT_ELITE) {
            linear_interpolate(
                score,
                CREDIT_INIT,
                CREDIT_ELITE,
                COST_REPAIR_END,
                COST_ACCUM_END
            )
        }
        // 区间3. 精英期 75 - 95
        else if (score <= CREDIT_MAX) {
            linear_interpolate(
                score,
                CREDIT_ELITE,
                CREDIT_MAX,
                COST_ACCUM_END,
                COST_ELITE_END
            )
        }
        // 避免报错，分数大于 95，直接返回最大成本
        else {
            COST_ELITE_END
        }
    }

    /// 积分计算加分 (Integrate Energy To Score)
    ///
    /// @param start_score: 起始分数
    /// @param energy: 能量
    /// @return 加分后的分数
    public(friend) fun integrate_energy_to_score(
        start_score: u64, energy: u64
    ): u64 {
        let current_score = start_score;
        let remaining_energy = energy;

        // 1. 尝试通过 区间1 (修复期)
        if (current_score < CREDIT_INIT && remaining_energy > 0) {
            let (new_score, used_energy) =
                solve_segment_integral(
                    current_score,
                    CREDIT_INIT,
                    COST_REPAIR_START,
                    COST_REPAIR_END,
                    remaining_energy,
                    CREDIT_MIN,
                    CREDIT_INIT
                );
            current_score = new_score;
            remaining_energy -= used_energy;
        };
        // 2. 尝试通过 区间2 (积累期)
        if (current_score >= CREDIT_INIT
            && current_score < CREDIT_ELITE
            && remaining_energy > 0) {
            let (new_score, used_energy) =
                solve_segment_integral(
                    current_score,
                    CREDIT_ELITE,
                    COST_REPAIR_END,
                    COST_ACCUM_END,
                    remaining_energy,
                    CREDIT_INIT,
                    CREDIT_ELITE
                );
            current_score = new_score;
            remaining_energy -= used_energy;
        };
        // 3. 尝试通过 区间3 (精英期)
        if (current_score >= CREDIT_ELITE && remaining_energy > 0) {
            let (new_score, used_energy) =
                solve_segment_integral(
                    current_score,
                    CREDIT_MAX,
                    COST_ACCUM_END,
                    COST_ELITE_END,
                    remaining_energy,
                    CREDIT_ELITE,
                    CREDIT_MAX
                );
            current_score = new_score;
            // 忽略剩余能量，因为已达上限或能量耗尽
            _ = used_energy;
        };

        current_score
    }

    /// 积分计算扣分 (Deduct Energy From Score) - 逆向积分
    ///
    /// @param start_score: 起始分数
    /// @param energy: 需要扣除的能量
    /// @return 扣分后的分数
    public(friend) fun deduct_energy_from_score(
        start_score: u64, energy: u64
    ): u64 {
        let current_score = start_score;
        let remaining_energy = energy;

        // 逆序处理区间：精英 -> 积累 -> 修复

        // 3. 尝试回退 区间3 (精英期)
        if (current_score > CREDIT_ELITE && remaining_energy > 0) {
            let (new_score, used_energy) =
                solve_segment_inverse(
                    current_score,
                    CREDIT_ELITE, // 向下回退到 threshold_elite
                    COST_ACCUM_END,
                    COST_ELITE_END,
                    remaining_energy,
                    CREDIT_ELITE,
                    CREDIT_MAX
                );
            current_score = new_score;
            remaining_energy -= used_energy;
        };

        // 2. 尝试回退 区间2 (积累期)
        if (current_score > CREDIT_INIT
            && current_score <= CREDIT_ELITE
            && remaining_energy > 0) {
            let (new_score, used_energy) =
                solve_segment_inverse(
                    current_score,
                    CREDIT_INIT, // 向下回退到 threshold_repair
                    COST_REPAIR_END,
                    COST_ACCUM_END,
                    remaining_energy,
                    CREDIT_INIT,
                    CREDIT_ELITE
                );
            current_score = new_score;
            remaining_energy -= used_energy;
        };

        // 1. 尝试回退 区间1 (修复期)
        if (current_score > CREDIT_MIN
            && current_score <= CREDIT_INIT
            && remaining_energy > 0) {
            let (new_score, used_energy) =
                solve_segment_inverse(
                    current_score,
                    CREDIT_MIN, // 向下回退到 min_score
                    COST_REPAIR_START,
                    COST_REPAIR_END,
                    remaining_energy,
                    CREDIT_MIN,
                    CREDIT_INIT
                );
            current_score = new_score;
            // 忽略剩余能量，因为已达下限
            _ = used_energy;
        };

        current_score
    }

    /// 计算衰减后的分数 (Calculate Decayed Score)
    ///
    /// @param current_score: 当前分数
    /// @param last_update_time: 上次更新时间
    /// @param now: 当前时间
    /// @return 衰减后的分数
    public(friend) fun calculate_decayed_score(
        current_score: u64, last_update_time: u64, now: u64
    ): u64 {
        // 1. 检查是否在宽限期(豁免期)内
        if (now <= last_update_time + DECAY_GRACE_PERIOD) {
            return current_score
        };

        // 2. 计算已过期的秒数 (不包含宽限期)
        let decay_duration = (now - last_update_time) - DECAY_GRACE_PERIOD;

        // 3. 计算总能量衰减
        // 公式：TotalEnergy = Duration * (DailyBase / 86400)
        let total_decay_energy = (decay_duration * ENERGY_DECAY_BASE) / 86400;

        // 4. 执行积分扣除
        if (total_decay_energy > 0) {
            deduct_energy_from_score(current_score, total_decay_energy)
        } else {
            current_score
        }
    }

    /// 计算惩罚后的分数 (Calculate Slashed Score)
    /// 用于 TaskMarket 计算出的违约惩罚
    ///
    /// @param current_score: 当前分数
    /// @param penalty_energy: 惩罚能量
    /// @return 惩罚后的分数
    public(friend) fun calculate_slashed_score(
        current_score: u64, penalty_energy: u64
    ): u64 {
        // 虽然现在只是单纯调用了 deduct_energy_from_score
        // 但是未来业务变更，例如决定对“惩罚”加收 10% 的额外手续费，或者修改惩罚系数
        // 我们可以只修改 calculate_slashed_score 的内部逻辑
        // 而不会影响到自然衰减的逻辑
        deduct_energy_from_score(current_score, penalty_energy)
    }

    /// 计算任务获得的能量
    public(friend) fun calculate_energy_gain(difficulty: u64, count: u64): u64 {
        difficulty * count * ENERGY_SCALING_FACTOR
    }

    // Getter 方法 ----------------------------------------------------

    /// 获取初始分数
    public fun get_credit_init(): u64 {
        CREDIT_INIT
    }

    /// 获取最大分数
    public fun get_credit_max(): u64 {
        CREDIT_MAX
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
        let cost_at_max = cost_end; // 本段终点的 Cost 固定

        // 2. 试算：如果跑完整个区间，需要多少能量？
        //    使用梯形面积公式：Area = (上底 + 下底) * 高 / 2
        //    Full Energy = (Cost_start + Cost_end) * Dist / 2
        let avg_cost = (cost_at_start + cost_at_max) / 2;
        let dist = max_s - start_s;
        let full_segment_energy = (avg_cost * dist) / DECIMALS;

        // 3. 判断能量是否足够跑完本段 (Full Segment Check)
        if (available_energy >= full_segment_energy) {
            // A. 能量充足，直接到达本段终点，消耗 full_segment_energy
            return (max_s, full_segment_energy)
        } else {
            // B. 能量不足，将在中途停下。我们需要求解 target_s。
            //    Energy ~= Cost * dx  =>  dx ~= Energy / Cost

            // [Step 1] 一阶近似 (First-order Approximation)
            // 假设 Cost 不变，等于起点的 Cost。
            // dx_est = (available_energy * DECIMALS) / cost_at_start;
            let dx_est = (available_energy * DECIMALS) / cost_at_start;
            let target_s = start_s + dx_est;

            // Clamp (防止估算过大超出本段)
            if (target_s > max_s) {
                target_s = max_s;
            };

            // [Step 2] 二阶修正 (Trapezoidal Correction)
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
            let dx_refined = (available_energy * DECIMALS) / avg_cost_est;

            // 得到最终落点
            let final_s = start_s + dx_refined;
            if (final_s > max_s) {
                final_s = max_s;
            };

            // 返回最终落点
            (final_s, available_energy)
        }
    }

    /// 求解单段逆积分 (Solve Segment Inverse) - 用于扣分
    ///
    /// 核心逻辑：给定能量扣除，分数会下降多少？
    /// 方向：从 start_s (高分) -> min_s (低分)
    ///
    /// @param start_s: 起始分数 (高)
    /// @param min_s: 本段终点分数 (低)
    /// @param cost_min: 低分点对应的能量成本
    /// @param cost_max: 高分点对应的能量成本
    /// @param available_energy: 需要扣除的能量
    /// @param seg_min: 该段定义的最小分数
    /// @param seg_max: 该段定义的最大分数
    /// @return (新分数, 实际消耗的能量)
    fun solve_segment_inverse(
        start_s: u64,
        min_s: u64,
        cost_min: u64, // 注意：cost_min 是 seg_min 对应的 Cost
        cost_max: u64, // 注意：cost_max 是 seg_max 对应的 Cost
        available_energy: u64,
        seg_min: u64,
        seg_max: u64
    ): (u64, u64) {
        // 0. 如果起点已经低于终点，无法在此区间移动
        if (start_s <= min_s) return (start_s, 0);

        // 1. 计算起点的瞬时成本 Cost(start)
        let cost_at_start = linear_interpolate(
            start_s, seg_min, seg_max, cost_min, cost_max
        );
        // 本段终点 (min_s) 的瞬时成本。如果 min_s == seg_min，则为 cost_min，否则插值计算
        let cost_at_min = linear_interpolate(min_s, seg_min, seg_max, cost_min, cost_max);

        // 2. 试算：如果回退完整个区间，需要多少能量？
        let avg_cost = (cost_at_start + cost_at_min) / 2;
        let dist = start_s - min_s;
        let full_segment_energy = (avg_cost * dist) / DECIMALS;

        // 3. 判断能量是否足够回退完本段
        if (available_energy >= full_segment_energy) {
            // A. 能量充足，直接到达本段终点 (min_s)
            return (min_s, full_segment_energy)
        } else {
            // B. 能量不足，中途停下。
            //    Backward: Energy ~= Cost * dx
            //    但是随着分数降低，Cost 会降低。

            // [Step 1] 一阶近似
            // 假设 Cost 不变，使用起点 Cost (Highest in segment path)
            let dx_est = (available_energy * DECIMALS) / cost_at_start;
            // 注意：因为是扣分，所以在 start_s 基础上减去
            let target_s = if (start_s > dx_est) {
                start_s - dx_est
            } else { min_s };

            if (target_s < min_s) {
                target_s = min_s;
            };

            // [Step 2] 二阶修正
            let cost_mid = linear_interpolate(
                target_s, seg_min, seg_max, cost_min, cost_max
            );
            let avg_cost_est = (cost_at_start + cost_mid) / 2;
            let dx_refined = (available_energy * DECIMALS) / avg_cost_est;

            let final_s =
                if (start_s > dx_refined) {
                    start_s - dx_refined
                } else { min_s };
            if (final_s < min_s) {
                final_s = min_s;
            };

            (final_s, available_energy)
        }
    }
}

