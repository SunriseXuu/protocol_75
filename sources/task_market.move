module protocol_75::task_market {
    use std::vector;

    // =========================================================================
    // Error Codes (错误码)
    // =========================================================================
    /// 任务参数数值异常（如为0）
    const E_INVALID_PARAM: u64 = 1;
    /// 任务列表为空
    const E_NO_TASKS: u64 = 2;
    /// 参数数量不匹配
    const E_PARAM_MISMATCH: u64 = 3;

    // =========================================================================
    // Struct Definitions (数据结构)
    // =========================================================================

    /// 原子任务类型
    /// id: 1=跑步(Run), 2=早睡(Sleep), 3=冥想(Meditate)
    /// weight: 基础难度权重
    struct TaskType has copy, drop, store {
        id: u8,             
        weight: u64,   
    }

    /// 任务规格说明书 (DTO)
    /// 用户传入的参数包，包含任务列表和对应的具体参数（如米数、分钟数）
    struct TaskSpec has copy, drop, store {
        tasks: vector<TaskType>,
        params: vector<u64>, 
    }

    // =========================================================================
    // Public Functions (核心逻辑)
    // =========================================================================

    /// 辅助函数：快速创建一个 TaskType
    public fun new_task_type(id: u8): TaskType {
        // 简单配置表：硬编码不同任务的权重
        let weight = if (id == 1) { 10 }      // 跑步: 权重高
        else if (id == 2) { 5 }               // 早睡: 权重中
        else if (id == 3) { 3 }               // 冥想: 权重低
        else { 0 };                           // 未知任务
        
        TaskType { id, weight }
    }

    /// 辅助函数：快速创建一个 TaskSpec
    public fun new_task_spec(tasks: vector<TaskType>, params: vector<u64>): TaskSpec {
        TaskSpec { tasks, params }
    }

    /// 验证任务参数是否合法
    public fun validate_spec(spec: &TaskSpec): bool {
        let len = vector::length(&spec.tasks);
        
        // 1. 基础检查
        if (len == 0) { return false };
        if (len != vector::length(&spec.params)) { return false };

        let i = 0;
        while (i < len) {
            let task = vector::borrow(&spec.tasks, i);
            let param = *vector::borrow(&spec.params, i);

            // 2. 检查任务ID是否有效 (权重为0说明ID无效)
            if (task.weight == 0) { return false };
            // 3. 检查参数是否大于0 (例如不能跑0米)
            if (param == 0) { return false };

            i = i + 1;
        };
        true
    }

    /// 计算综合难度系数
    /// 算法示例: Sum(TaskWeight * Param)
    public fun calculate_difficulty(spec: &TaskSpec): u64 {
        // 先验证参数
        assert!(validate_spec(spec), E_INVALID_PARAM);

        let total_difficulty = 0u64;
        let len = vector::length(&spec.tasks);
        let i = 0;

        while (i < len) {
            let task = vector::borrow(&spec.tasks, i);
            let param = *vector::borrow(&spec.params, i);

            // 简单算法：权重 * 参数
            // 实际场景中可能需要除以 ScalingFactor 防止数值过大
            total_difficulty = total_difficulty + (task.weight * param);

            i = i + 1;
        };

        total_difficulty
    }

    /// 视图函数：获取某个任务ID的权重
    #[view]
    public fun get_task_weight(task_id: u8): u64 {
        let task = new_task_type(task_id);
        task.weight
    }

    // =========================================================================
    // Unit Tests (单元测试)
    // =========================================================================
    
    #[test_only]
    module tests {
        use super::*;
        use std::vector;

        #[test]
        fun test_calculate_difficulty() {
            // 1. 准备任务：跑步(10) + 早睡(5)
            let tasks = vector::empty<TaskType>();
            vector::push_back(&mut tasks, new_task_type(1));
            vector::push_back(&mut tasks, new_task_type(2));

            // 2. 准备参数：5(km) + 8(h)
            let params = vector::empty<u64>();
            vector::push_back(&mut params, 5);
            vector::push_back(&mut params, 8);

            let spec = new_task_spec(tasks, params);

            // 3. 计算：(10 * 5) + (5 * 8) = 50 + 40 = 90
            let diff = calculate_difficulty(&spec);
            
            assert!(diff == 90, 0);
        }

        #[test]
        #[expected_failure(abort_code = E_INVALID_PARAM)]
        fun test_fail_zero_param() {
            // 测试非法参数：跑 0 米
            let tasks = vector::singleton(new_task_type(1));
            let params = vector::singleton(0); 
            let spec = new_task_spec(tasks, params);
            
            // 应该报错并中止
            calculate_difficulty(&spec); 
        }
    }
}