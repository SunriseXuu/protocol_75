/// # 测试稳定币 (Test USD)
///
/// ## 功能描述
/// 本模块用于在测试网 (Testnet) 环境中模拟稳定币 (如 USDT/USDC)。
/// 它提供了一个开放的“水龙头”机制 (Faucet)，允许开发者和测试用户自由铸造代币，
/// 以便调试协议的支付、质押和结算流程。
///
/// ## 主要特性
/// 1. **管理代币 (Managed Coin)**：由模块本身管理 Mint/Burn/Freeze 能力。
/// 2. **水龙头 (Faucet)**：公开的 `mint` 入口，任何人都可以给自己发钱。
/// 3. **测试辅助**：提供 `#[test_only]` 函数供单元测试快速初始化。
///
/// ## 警告
/// **仅限测试网使用**。主网部署时请勿包含此模块，而是直接集成真实的稳定币地址。
module protocol_75::test_usd {
    use std::signer;
    use std::string;
    use aptos_framework::coin::{Self, BurnCapability, FreezeCapability, MintCapability};

    // 数据结构 (Data Structures) ---------------------------------------

    /// 稳定币的标记结构体 (Phantom Type)
    struct TestUSD {}

    /// 权限能力存储 (Capabilities)
    /// 集中管理代币的铸造、销毁和冻结权限，存储在管理员账户下。
    struct Caps has key {
        burn: BurnCapability<TestUSD>,
        freeze: FreezeCapability<TestUSD>,
        mint: MintCapability<TestUSD>
    }

    // 用户接口 (User Entries) ----------------------------------------

    /// 初始化代币 (Initialize)
    ///
    /// 部署合约后需立即调用此函数，注册 coin info 并存储权限能力。
    ///
    /// @param admin: 管理员账户签名 (@protocol_75)
    public entry fun initialize(admin: &signer) {
        let (burn, freeze, mint) =
            coin::initialize<TestUSD>(
                admin,
                string::utf8(b"Test USD"), // 代币名称
                string::utf8(b"AUDT"), // 代币符号
                6, // 精度 (6位小数)
                false //以前是 true，为解决 Fungible Asset 元数据兼容性问题改为 false
            );
        move_to(admin, Caps { burn, freeze, mint });
    }

    /// 水龙头：领取测试币 (Mint / Faucet)
    ///
    /// 任何用户都可以调用此函数为自己铸造测试币。
    /// 如果用户尚未注册 CoinStore，会自动为其注册。
    ///
    /// @param user: 接收者签名 (任意用户)
    /// @param amount: 铸造金额 (注意精度，1 AUDT = 1,000,000)
    public entry fun mint(user: &signer, amount: u64) acquires Caps {
        let caps = borrow_global<Caps>(@protocol_75);
        let coins = coin::mint(amount, &caps.mint);
        let user_addr = signer::address_of(user);

        // 自动注册 CoinStore，优化用户体验
        if (!coin::is_account_registered<TestUSD>(user_addr)) {
            coin::register<TestUSD>(user);
        };
        coin::deposit(user_addr, coins);
    }

    /// 销毁代币 (Burn)
    ///
    /// 用户可以销毁自己持有的代币。通常用于测试销毁逻辑。
    ///
    /// @param user: 代币持有者签名
    /// @param amount: 销毁金额
    public entry fun burn(user: &signer, amount: u64) acquires Caps {
        let caps = borrow_global<Caps>(@protocol_75);
        let coins = coin::withdraw<TestUSD>(user, amount);
        coin::burn(coins, &caps.burn);
    }

    // 单元测试 (Unit Tests) --------------------------------------------

    #[test_only]
    /// 测试专用：初始化
    public fun init_for_test(account: &signer) {
        initialize(account);
    }

    #[test_only]
    /// 测试专用：铸造代币对象 (不直接存入账户，返回 Coin 对象)
    public fun mint_for_test(account: &signer, amount: u64): coin::Coin<TestUSD> acquires Caps {
        let caps = borrow_global<Caps>(std::signer::address_of(account));
        coin::mint(amount, &caps.mint)
    }

    #[test_only]
    /// 测试专用：销毁代币对象
    public fun burn_for_test(coin: coin::Coin<TestUSD>) acquires Caps {
        let caps = borrow_global<Caps>(@protocol_75);
        coin::burn(coin, &caps.burn);
    }
}

