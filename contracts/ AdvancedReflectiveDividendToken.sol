// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*
    AdvancedERC314DividendToken

    这是一个功能型 ERC20 合约，包含：

    1. 标准 ERC20。
    2. ERC314 风格内置买卖池。
    3. ERC314 买卖滑点保护。
    4. 分红功能。
    5. 冻结账户。
    6. 买入税、卖出税、普通转账税。
    7. ERC314 白名单优先买入、优先卖出。
    8. AMM 白名单优先买入、优先卖出。
    9. 暂停公开 ERC314 兑换。
    10. 暂停公开 PancakeSwap / Uniswap 买卖。
    11. 多权限管理。
    12. 权限丢弃，使用 AccessControl 自带 renounceRole。
    13. 调用 UniswapV2 / PancakeSwapV2 Router 买卖。
    14. 添加和移除 UniswapV2 / PancakeSwapV2 流动性。
    15. ERC314 内置流动性管理。
    16. 税前预览和税后预览。
    17. 分红数学使用 Math.mulDiv，降低极端情况下溢出风险。
    18. rescueToken 允许救援超额分红币，但不能动用户应得分红。
    19. ERC314 储备手动同步带 5% 单次偏差限制和冷却时间。
    20. Router 更新时支持选择是否清理旧 Pair 标记。

    依赖：
    npm install @openzeppelin/contracts

    OpenZeppelin 建议版本：
    5.x

    重要说明：
    ERC314 不是像 ERC20/ERC721 那样的正式广泛标准。
    这里实现的是市场常见的 ERC314 风格：

    - 用户给合约转 ETH/BNB，合约按内部池子价格给用户发币。
    - 用户把币卖给合约，合约按内部池子价格返 ETH/BNB。

    安全建议：
    正式上线时，建议关闭 transfer(address(this), amount) 自动卖出。
    用户买卖建议统一调用：
    - erc314Buy(amountOutMin)
    - erc314Sell(tokenAmount, minNativeOut)
*/

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

/// @notice UniswapV2 / PancakeSwapV2 Router 简化接口
interface IUniswapV2Router02 {
    /// @notice 获取 WETH/WBNB 地址
    function WETH() external pure returns (address);

    /// @notice 获取 Factory 地址
    function factory() external pure returns (address);

    /// @notice 支持扣税币的 Token 卖 ETH/BNB 方法
    function swapExactTokensForETHSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external;

    /// @notice 支持扣税币的 ETH/BNB 买 Token 方法
    function swapExactETHForTokensSupportingFeeOnTransferTokens(
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external payable;

    /// @notice 添加 Token + ETH/BNB 流动性
    function addLiquidityETH(
        address token,
        uint256 amountTokenDesired,
        uint256 amountTokenMin,
        uint256 amountETHMin,
        address to,
        uint256 deadline
    )
        external
        payable
        returns (
            uint256 amountToken,
            uint256 amountETH,
            uint256 liquidity
        );

    /// @notice 支持扣税币的移除 Token + ETH/BNB 流动性
    function removeLiquidityETHSupportingFeeOnTransferTokens(
        address token,
        uint256 liquidity,
        uint256 amountTokenMin,
        uint256 amountETHMin,
        address to,
        uint256 deadline
    ) external returns (uint256 amountETH);
}

/// @notice UniswapV2 / PancakeSwapV2 Factory 简化接口
interface IUniswapV2Factory {
    /// @notice 创建交易对
    function createPair(address tokenA, address tokenB) external returns (address pair);

    /// @notice 查询交易对
    function getPair(address tokenA, address tokenB) external view returns (address pair);
}

/// @title AdvancedERC314DividendToken
/// @notice 支持 ERC314、分红、冻结、税费、白名单、权限、UniswapV2 流动性的 ERC20 合约
contract AdvancedERC314DividendToken is ERC20, AccessControl, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    // =============================================================
    // 一、权限角色
    // =============================================================

    /// @notice 税费管理员：可以设置买税、卖税、转账税、收税钱包
    bytes32 public constant TAX_MANAGER_ROLE = keccak256("TAX_MANAGER_ROLE");

    /// @notice 白名单管理员：可以设置 ERC314 白名单和 AMM 白名单
    bytes32 public constant WHITELIST_MANAGER_ROLE = keccak256("WHITELIST_MANAGER_ROLE");

    /// @notice 冻结管理员：可以冻结和解冻账户
    bytes32 public constant FREEZER_ROLE = keccak256("FREEZER_ROLE");

    /// @notice 暂停管理员：可以暂停转账、开启或关闭公开买卖
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    /// @notice 分红管理员：可以设置分红币、发放分红、设置单次分红上限
    bytes32 public constant DIVIDEND_MANAGER_ROLE = keccak256("DIVIDEND_MANAGER_ROLE");

    /// @notice 流动性管理员：可以管理 ERC314 池子和 Uniswap/PancakeSwap 流动性
    bytes32 public constant LIQUIDITY_MANAGER_ROLE = keccak256("LIQUIDITY_MANAGER_ROLE");

    // =============================================================
    // 二、基础参数
    // =============================================================

    /// @notice 税费分母，10000 表示 100%
    uint256 public constant BPS_DENOMINATOR = 10_000;

    /// @notice 最大税费，2000 表示最高 20%
    uint256 public constant MAX_TAX_BPS = 2_000;

    /// @notice 批量操作最大数量，防止数组太大导致 gas 爆炸
    uint256 public constant MAX_BATCH_SIZE = 200;

    /// @notice 为了分红数学安全，限制初始总供应量不超过 uint128 最大值
    uint256 public constant MAX_SAFE_TOTAL_SUPPLY = type(uint128).max;

    /// @notice 单次最大分红安全硬上限
    /// @dev type(uint256).max / 2^128，避免极端情况下放大计算过大
    uint256 public constant MAX_SAFE_DIVIDEND_DISTRIBUTION_AMOUNT = type(uint256).max / (2 ** 128);

    /// @notice ERC314 手动同步储备时，单次最大允许偏差，500 = 5%
    uint256 public constant MAX_RESERVE_SYNC_DEVIATION_BPS = 500;

    /// @notice 储备同步冷却时间最大值，防止管理员误设置成超长时间
    uint256 public constant MAX_RESERVE_SYNC_COOLDOWN = 7 days;

    /// @notice 收税钱包，扣下来的税会转到这个地址
    address public feeReceiver;

    /// @notice 买入税，例如 300 表示 3%
    uint256 public buyTaxBps;

    /// @notice 卖出税，例如 300 表示 3%
    uint256 public sellTaxBps;

    /// @notice 普通转账税，例如 100 表示 1%
    uint256 public transferTaxBps;

    /// @notice 是否免税
    mapping(address => bool) public isTaxExempt;

    /// @notice 是否被冻结
    mapping(address => bool) public isFrozen;

    /// @notice 是否是 AMM 交易对，例如 PancakeSwap Pair
    mapping(address => bool) public isAmmPair;

    /// @notice 单次最大分红数量，项目方可以根据 rewardToken 精度调整
    uint256 public maxDividendDistributionAmount = 1_000_000_000 * 1e18;

    /// @notice ERC314 储备同步冷却时间，默认 12 小时
    uint256 public erc314ReserveSyncCooldown = 12 hours;

    /// @notice 上一次手动同步 ERC314 储备的时间
    uint256 public lastErc314ReserveSyncAt;

    // =============================================================
    // 三、白名单和交易开关
    // =============================================================

    /// @notice ERC314 内置池子是否允许公开买卖
    bool public publicErc314SwapEnabled;

    /// @notice AMM 是否允许公开买卖，例如 PancakeSwap / Uniswap
    bool public publicAmmSwapEnabled;

    /*
        是否允许 transfer(address(this), amount) 自动卖出。

        默认关闭。
        原因：
        - transfer 自动卖出没有 minNativeOut。
        - 没有滑点保护。
        - 容易被夹子攻击。

        正式建议：
        用户卖出统一调用 erc314Sell(tokenAmount, minNativeOut)。
    */
    bool public erc314SellByTransferEnabled;

    /// @notice ERC314 买入白名单
    mapping(address => bool) public erc314WhitelistBuy;

    /// @notice ERC314 卖出白名单
    mapping(address => bool) public erc314WhitelistSell;

    /// @notice AMM 买入白名单
    mapping(address => bool) public ammWhitelistBuy;

    /// @notice AMM 卖出白名单
    mapping(address => bool) public ammWhitelistSell;

    // =============================================================
    // 四、ERC314 内置池子参数
    // =============================================================

    /*
        ERC314 内置池子使用 x * y = k 的 AMM 公式。

        erc314NativeReserve：
        合约记录的 ETH/BNB 储备。

        erc314TokenReserve：
        合约记录的代币储备。

        注意：
        记录储备和合约真实余额不是一个东西。
        别人可以强行给合约转 ETH/BNB，导致 address(this).balance 变多。
        但是 ERC314 计价只看下面这两个 reserve。
    */

    /// @notice ERC314 池子记录的 ETH/BNB 储备
    uint256 public erc314NativeReserve;

    /// @notice ERC314 池子记录的代币储备
    uint256 public erc314TokenReserve;

    /// @notice ERC314 内置池子手续费，30 表示 0.3%
    uint256 public erc314SwapFeeBps = 30;

    /// @notice ERC314 锁的未进入状态
    uint256 private constant ERC314_NOT_ENTERED = 1;

    /// @notice ERC314 锁的已进入状态
    uint256 private constant ERC314_ENTERED = 2;

    /// @notice ERC314 当前锁状态
    uint256 private erc314SwapLockStatus = ERC314_NOT_ENTERED;

    /// @notice ERC314 专用防重入锁，保护 ERC314 内置池子买卖和流动性移除
    modifier erc314SwapLock() {
        require(erc314SwapLockStatus == ERC314_NOT_ENTERED, "erc314 swap locked");
        erc314SwapLockStatus = ERC314_ENTERED;
        _;
        erc314SwapLockStatus = ERC314_NOT_ENTERED;
    }

    // =============================================================
    // 五、UniswapV2 / PancakeSwapV2 参数
    // =============================================================

    /// @notice UniswapV2 / PancakeSwapV2 Router 地址
    IUniswapV2Router02 public router;

    /// @notice 主交易对地址，通常是 Token-WETH 或 Token-WBNB Pair
    address public mainPair;

    // =============================================================
    // 六、分红参数
    // =============================================================

    /*
        分红使用“每股累计分红”模型。

        好处：
        - 不需要循环所有持币人。
        - 不会因为持币人太多导致发分红失败。
        - 用户自己领取分红。

        数学安全：
        - 分红相关乘除全部使用 Math.mulDiv。
        - 避免 shares * magnifiedDividendPerShare 普通乘法溢出。
    */

    /// @notice 分红币地址，例如 USDT/BUSD/USDC
    IERC20 public rewardToken;

    /// @notice 放大倍数，用来处理 Solidity 没有小数的问题
    uint256 private constant MAGNITUDE = 2 ** 128;

    /// @notice 每 1 个有效分红份额累计能分到多少奖励，已经放大 MAGNITUDE 倍
    uint256 public magnifiedDividendPerShare;

    /// @notice 每个地址的有效分红份额
    mapping(address => uint256) public dividendShares;

    /// @notice 每个地址已经记账过的分红债务
    mapping(address => uint256) public dividendDebt;

    /// @notice 每个地址已经结算但还没领取的分红
    mapping(address => uint256) public pendingDividends;

    /// @notice 总有效分红份额
    uint256 public totalDividendShares;

    /// @notice 是否排除分红
    mapping(address => bool) public isDividendExcluded;

    /// @notice 累计发放分红数量
    uint256 public totalDividendsDistributed;

    /// @notice 累计领取分红数量
    uint256 public totalDividendsClaimed;

    // =============================================================
    // 七、事件
    // =============================================================

    event TaxesUpdated(uint256 buyTaxBps, uint256 sellTaxBps, uint256 transferTaxBps);
    event FeeReceiverUpdated(address indexed feeReceiver);
    event FeeReceiverTaxExemptCleared(address indexed oldFeeReceiver);
    event TaxExemptUpdated(address indexed account, bool exempt);

    event Frozen(address indexed account, bool frozen);

    event PublicErc314SwapUpdated(bool enabled);
    event PublicAmmSwapUpdated(bool enabled);
    event Erc314SellByTransferUpdated(bool enabled);

    event Erc314WhitelistBuyUpdated(address indexed account, bool enabled);
    event Erc314WhitelistSellUpdated(address indexed account, bool enabled);
    event AmmWhitelistBuyUpdated(address indexed account, bool enabled);
    event AmmWhitelistSellUpdated(address indexed account, bool enabled);

    event Erc314Buy(address indexed buyer, uint256 nativeIn, uint256 grossTokenOut, uint256 netTokenOut);
    event Erc314Sell(address indexed seller, uint256 grossTokenIn, uint256 netTokenIn, uint256 nativeOut);

    event Erc314LiquidityAdded(address indexed provider, uint256 tokenAmount, uint256 nativeAmount);
    event Erc314LiquidityRemoved(address indexed receiver, uint256 tokenAmount, uint256 nativeAmount);
    event Erc314ReservesSynced(uint256 tokenReserve, uint256 nativeReserve);
    event Erc314SwapFeeUpdated(uint256 oldFeeBps, uint256 newFeeBps);
    event Erc314ReserveSyncCooldownUpdated(uint256 oldCooldown, uint256 newCooldown);

    event RouterUpdated(address indexed router);
    event AmmPairUpdated(address indexed pair, bool enabled);

    event RewardTokenUpdated(address indexed rewardToken);
    event MaxDividendDistributionAmountUpdated(uint256 oldAmount, uint256 newAmount);
    event DividendExcludedUpdated(address indexed account, bool excluded);
    event DividendsDistributed(address indexed from, uint256 amount);
    event DividendsClaimed(address indexed account, uint256 amount);

    event RescueETH(address indexed to, uint256 amount);
    event RescueToken(address indexed token, address indexed to, uint256 amount);

    // =============================================================
    // 八、构造函数
    // =============================================================

    /// @notice 构造函数，部署时初始化代币和管理员
    /// @param name_ 代币名称，例如 "BKC Token"
    /// @param symbol_ 代币符号，例如 "BKC"
    /// @param initialSupply_ 初始发行量，注意这里需要传带 decimals 的数量，例如 1亿枚 18 位小数就是 100000000 * 1e18
    /// @param owner_ 初始管理员地址，会拿到所有权限
    /// @param feeReceiver_ 收税钱包地址，不能是合约自己
    /// @param router_ UniswapV2/PancakeSwapV2 Router 地址，如果暂时不设置可以传 address(0)
    /// @param rewardToken_ 分红币地址，例如 USDT/BUSD/USDC，如果暂时不设置可以传 address(0)
    constructor(
        string memory name_,
        string memory symbol_,
        uint256 initialSupply_,
        address owner_,
        address feeReceiver_,
        address router_,
        address rewardToken_
    ) ERC20(name_, symbol_) {
        require(owner_ != address(0), "owner is zero");
        require(feeReceiver_ != address(0), "feeReceiver is zero");
        require(feeReceiver_ != address(this), "feeReceiver cannot be token");
        require(initialSupply_ <= MAX_SAFE_TOTAL_SUPPLY, "supply too large");

        feeReceiver = feeReceiver_;

        _grantRole(DEFAULT_ADMIN_ROLE, owner_);
        _grantRole(TAX_MANAGER_ROLE, owner_);
        _grantRole(WHITELIST_MANAGER_ROLE, owner_);
        _grantRole(FREEZER_ROLE, owner_);
        _grantRole(PAUSER_ROLE, owner_);
        _grantRole(DIVIDEND_MANAGER_ROLE, owner_);
        _grantRole(LIQUIDITY_MANAGER_ROLE, owner_);

        isTaxExempt[owner_] = true;
        isTaxExempt[address(this)] = true;
        isTaxExempt[feeReceiver_] = true;

        isDividendExcluded[address(0)] = true;
        isDividendExcluded[address(this)] = true;
        isDividendExcluded[feeReceiver_] = true;

        if (rewardToken_ != address(0)) {
            require(rewardToken_ != address(this), "reward cannot self");
            rewardToken = IERC20(rewardToken_);
            emit RewardTokenUpdated(rewardToken_);
        }

        if (router_ != address(0)) {
            _setRouter(router_, false);
        }

        _mint(owner_, initialSupply_);

        publicErc314SwapEnabled = false;
        publicAmmSwapEnabled = false;
        erc314SellByTransferEnabled = false;
    }

    // =============================================================
    // 九、接收 ETH/BNB
    // =============================================================

    /// @notice 直接给合约转 ETH/BNB 时触发 ERC314 买入
    /// @dev 这个入口没有 amountOutMin，所以没有滑点保护；公开交易后只建议白名单兼容使用
    receive() external payable nonReentrant erc314SwapLock {
        require(
            !publicErc314SwapEnabled || erc314WhitelistBuy[msg.sender],
            "direct ETH disabled; use erc314Buy"
        );

        _erc314Buy(msg.sender, msg.value);
    }

    // =============================================================
    // 十、ERC20 标准转账入口
    // =============================================================

    /// @notice 标准 ERC20 转账
    /// @param to 接收地址
    /// @param amount 转账数量
    /// @return 是否成功
    function transfer(address to, uint256 amount) public override returns (bool) {
        address from = _msgSender();

        if (to == address(this) && erc314SellByTransferEnabled) {
            _erc314SellFromTransfer(from, amount);
            return true;
        }

        uint256 taxBps = _getTransferTaxBps(from, to);
        _transferWithTax(from, to, amount, taxBps, false);

        return true;
    }

    /// @notice 标准 ERC20 授权转账
    /// @param from 扣币地址
    /// @param to 接收地址
    /// @param amount 转账数量
    /// @return 是否成功
    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        address spender = _msgSender();

        _spendAllowance(from, spender, amount);

        if (to == address(this) && erc314SellByTransferEnabled) {
            _erc314SellFromTransfer(from, amount);
            return true;
        }

        uint256 taxBps = _getTransferTaxBps(from, to);
        _transferWithTax(from, to, amount, taxBps, false);

        return true;
    }

    // =============================================================
    // 十一、核心余额更新逻辑
    // =============================================================

    /// @notice OpenZeppelin ERC20 的核心余额更新钩子
    /// @dev 所有转账、铸币、销毁最终都会走这里，所以冻结和分红同步统一放这里
    /// @param from 扣币地址，铸币时是 address(0)
    /// @param to 收币地址，销毁时是 address(0)
    /// @param value 数量
    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && to != address(0)) {
            require(!paused(), "token paused");
        }

        if (from != address(0)) {
            require(!isFrozen[from], "from frozen");
        }

        if (to != address(0)) {
            require(!isFrozen[to], "to frozen");
        }

        if (from != address(0)) {
            _settleDividend(from);
        }

        if (to != address(0)) {
            _settleDividend(to);
        }

        super._update(from, to, value);

        if (from != address(0)) {
            _syncDividendShare(from);
        }

        if (to != address(0)) {
            _syncDividendShare(to);
        }
    }

    /// @notice 带税转账内部方法
    /// @param from 扣币地址
    /// @param to 收币地址
    /// @param amount 总转账数量
    /// @param taxBps 本次税率，单位 bps，例如 300 表示 3%
    /// @param ignoreContractTaxExempt 是否忽略合约自己的免税身份，ERC314 买卖时必须为 true
    function _transferWithTax(
        address from,
        address to,
        uint256 amount,
        uint256 taxBps,
        bool ignoreContractTaxExempt
    ) internal {
        require(from != address(0), "from zero");
        require(to != address(0), "to zero");
        require(amount > 0, "amount zero");

        /*
            AMM 白名单逻辑只管 PancakeSwap / Uniswap 用户买卖。

            这里跳过 from/to 为 address(this) 的情况：
            - 合约自己通过 Router 卖币，不应该被 AMM 白名单拦住。
            - 合约自己添加流动性，也不应该被 AMM 白名单拦住。
            - 用户直接和 Pair 交易，仍然会被白名单限制。
        */
        if (
            _isAmmSwap(from, to) &&
            !publicAmmSwapEnabled &&
            from != address(this) &&
            to != address(this)
        ) {
            if (isAmmPair[from]) {
                require(ammWhitelistBuy[to], "amm buy not whitelisted");
            }

            if (isAmmPair[to]) {
                require(ammWhitelistSell[from], "amm sell not whitelisted");
            }
        }

        bool exempt;

        if (ignoreContractTaxExempt) {
            bool fromExempt = from != address(this) && isTaxExempt[from];
            bool toExempt = to != address(this) && isTaxExempt[to];
            exempt = fromExempt || toExempt;
        } else {
            exempt = isTaxExempt[from] || isTaxExempt[to];
        }

        if (exempt || taxBps == 0) {
            _update(from, to, amount);
            return;
        }

        uint256 fee = (amount * taxBps) / BPS_DENOMINATOR;
        uint256 sendAmount = amount - fee;

        if (fee > 0) {
            _update(from, feeReceiver, fee);
        }

        _update(from, to, sendAmount);
    }

    /// @notice 根据转账方向判断应该收什么税
    /// @param from 扣币地址
    /// @param to 收币地址
    /// @return 本次税率，单位 bps
    function _getTransferTaxBps(address from, address to) internal view returns (uint256) {
        if (isAmmPair[from]) {
            return buyTaxBps;
        }

        if (isAmmPair[to]) {
            return sellTaxBps;
        }

        return transferTaxBps;
    }

    /// @notice 判断一次转账是否涉及 AMM 交易对
    /// @param from 扣币地址
    /// @param to 收币地址
    /// @return 是否涉及 AMM Pair
    function _isAmmSwap(address from, address to) internal view returns (bool) {
        return isAmmPair[from] || isAmmPair[to];
    }

    // =============================================================
    // 十二、ERC314 买入和卖出
    // =============================================================

    /// @notice ERC314 买入，带滑点保护
    /// @param amountOutMin 用户愿意接受的最低到账代币数量
    /// @return netTokenOut 用户实际到账代币数量，已经扣除买税
    function erc314Buy(uint256 amountOutMin)
        external
        payable
        nonReentrant
        erc314SwapLock
        returns (uint256 netTokenOut)
    {
        netTokenOut = _erc314Buy(msg.sender, msg.value);

        require(netTokenOut >= amountOutMin, "erc314 slippage");
    }

    /// @notice ERC314 卖出，带滑点保护
    /// @param tokenAmount 用户卖出的代币数量
    /// @param minNativeOut 用户愿意接受的最低 ETH/BNB 到账数量
    /// @return nativeOut 用户实际获得的 ETH/BNB 数量
    function erc314Sell(uint256 tokenAmount, uint256 minNativeOut)
        external
        nonReentrant
        erc314SwapLock
        returns (uint256 nativeOut)
    {
        nativeOut = _erc314Sell(msg.sender, tokenAmount);

        require(nativeOut >= minNativeOut, "erc314 slippage");
    }

    /// @notice transfer(address(this), amount) 自动卖出的内部包装
    /// @param seller 卖出用户
    /// @param tokenAmount 卖出的代币数量
    /// @return nativeOut 用户获得的 ETH/BNB 数量
    function _erc314SellFromTransfer(address seller, uint256 tokenAmount)
        internal
        erc314SwapLock
        returns (uint256 nativeOut)
    {
        nativeOut = _erc314Sell(seller, tokenAmount);
    }

    /// @notice ERC314 内部买入逻辑
    /// @param buyer 买入用户
    /// @param nativeAmount 用户支付的 ETH/BNB 数量
    /// @return netTokenOut 用户实际到账代币数量
    function _erc314Buy(address buyer, uint256 nativeAmount) internal returns (uint256 netTokenOut) {
        require(buyer != address(0), "buyer zero");
        require(nativeAmount > 0, "native zero");
        require(erc314NativeReserve > 0 && erc314TokenReserve > 0, "erc314 pool empty");

        if (!publicErc314SwapEnabled) {
            require(erc314WhitelistBuy[buyer], "erc314 buy not whitelisted");
        }

        uint256 grossTokenOut = getErc314AmountOut(
            nativeAmount,
            erc314NativeReserve,
            erc314TokenReserve
        );

        require(grossTokenOut > 0, "tokenOut zero");
        require(grossTokenOut < erc314TokenReserve, "insufficient token reserve");

        uint256 beforeBuyerBalance = balanceOf(buyer);

        erc314NativeReserve += nativeAmount;
        erc314TokenReserve -= grossTokenOut;

        _transferWithTax(address(this), buyer, grossTokenOut, buyTaxBps, true);

        netTokenOut = balanceOf(buyer) - beforeBuyerBalance;

        emit Erc314Buy(buyer, nativeAmount, grossTokenOut, netTokenOut);
    }

    /// @notice ERC314 内部卖出逻辑
    /// @param seller 卖出用户
    /// @param tokenAmount 用户卖出的代币数量
    /// @return nativeOut 用户获得的 ETH/BNB 数量
    function _erc314Sell(address seller, uint256 tokenAmount) internal returns (uint256 nativeOut) {
        require(seller != address(0), "seller zero");
        require(tokenAmount > 0, "token zero");
        require(erc314NativeReserve > 0 && erc314TokenReserve > 0, "erc314 pool empty");

        if (!publicErc314SwapEnabled) {
            require(erc314WhitelistSell[seller], "erc314 sell not whitelisted");
        }

        uint256 beforeContractTokenBalance = balanceOf(address(this));

        _transferWithTax(seller, address(this), tokenAmount, sellTaxBps, true);

        uint256 netTokenIn = balanceOf(address(this)) - beforeContractTokenBalance;
        require(netTokenIn > 0, "net token zero");

        nativeOut = getErc314AmountOut(
            netTokenIn,
            erc314TokenReserve,
            erc314NativeReserve
        );

        require(nativeOut > 0, "nativeOut zero");
        require(nativeOut < erc314NativeReserve, "insufficient native reserve");
        require(address(this).balance >= nativeOut, "native balance low");

        erc314TokenReserve += netTokenIn;
        erc314NativeReserve -= nativeOut;

        (bool ok, ) = payable(seller).call{value: nativeOut}("");
        require(ok, "native transfer failed");

        emit Erc314Sell(seller, tokenAmount, netTokenIn, nativeOut);
    }

    /// @notice 根据 AMM 公式预估输出数量，注意这是税前公式
    /// @param amountIn 输入数量
    /// @param reserveIn 输入资产储备
    /// @param reserveOut 输出资产储备
    /// @return 输出数量
    function getErc314AmountOut(
        uint256 amountIn,
        uint256 reserveIn,
        uint256 reserveOut
    ) public view returns (uint256) {
        require(amountIn > 0, "amountIn zero");
        require(reserveIn > 0 && reserveOut > 0, "bad reserves");

        uint256 amountInWithFee = amountIn * (BPS_DENOMINATOR - erc314SwapFeeBps);
        uint256 numerator = amountInWithFee * reserveOut;
        uint256 denominator = reserveIn * BPS_DENOMINATOR + amountInWithFee;

        return numerator / denominator;
    }

    /// @notice 预估 ERC314 买入能拿到多少代币，返回税前数量
    /// @param nativeAmount 输入的 ETH/BNB 数量
    /// @return tokenOut 税前预估输出代币数量
    function previewErc314Buy(uint256 nativeAmount) external view returns (uint256 tokenOut) {
        return getErc314AmountOut(nativeAmount, erc314NativeReserve, erc314TokenReserve);
    }

    /// @notice 预估 ERC314 卖出能拿到多少 ETH/BNB，返回未考虑卖税的税前数量
    /// @param tokenAmount 输入的代币数量
    /// @return nativeOut 税前预估输出 ETH/BNB 数量
    function previewErc314Sell(uint256 tokenAmount) external view returns (uint256 nativeOut) {
        return getErc314AmountOut(tokenAmount, erc314TokenReserve, erc314NativeReserve);
    }

    /// @notice 预估 ERC314 买入的税后到账数量
    /// @param buyer 买入用户地址
    /// @param nativeAmount 用户输入的 ETH/BNB 数量
    /// @return grossTokenOut 税前可获得的代币数量
    /// @return taxAmount 预计扣除的买入税
    /// @return netTokenOut 税后实际到账代币数量
    function previewErc314BuyNet(address buyer, uint256 nativeAmount)
        external
        view
        returns (
            uint256 grossTokenOut,
            uint256 taxAmount,
            uint256 netTokenOut
        )
    {
        require(buyer != address(0), "buyer zero");

        grossTokenOut = getErc314AmountOut(
            nativeAmount,
            erc314NativeReserve,
            erc314TokenReserve
        );

        bool buyerExempt = buyer != address(this) && isTaxExempt[buyer];

        if (buyerExempt || buyTaxBps == 0) {
            taxAmount = 0;
            netTokenOut = grossTokenOut;
        } else {
            taxAmount = (grossTokenOut * buyTaxBps) / BPS_DENOMINATOR;
            netTokenOut = grossTokenOut - taxAmount;
        }
    }

    /// @notice 预估 ERC314 卖出的税后 ETH/BNB 到账数量
    /// @param seller 卖出用户地址
    /// @param tokenAmount 用户准备卖出的代币数量
    /// @return grossTokenIn 用户输入的原始代币数量
    /// @return taxAmount 预计扣除的卖出税
    /// @return netTokenIn 扣税后真正进入 ERC314 池子的代币数量
    /// @return nativeOut 预计可获得的 ETH/BNB 数量
    function previewErc314SellNet(address seller, uint256 tokenAmount)
        external
        view
        returns (
            uint256 grossTokenIn,
            uint256 taxAmount,
            uint256 netTokenIn,
            uint256 nativeOut
        )
    {
        require(seller != address(0), "seller zero");
        require(tokenAmount > 0, "token zero");

        grossTokenIn = tokenAmount;

        bool sellerExempt = seller != address(this) && isTaxExempt[seller];

        if (sellerExempt || sellTaxBps == 0) {
            taxAmount = 0;
            netTokenIn = tokenAmount;
        } else {
            taxAmount = (tokenAmount * sellTaxBps) / BPS_DENOMINATOR;
            netTokenIn = tokenAmount - taxAmount;
        }

        nativeOut = getErc314AmountOut(
            netTokenIn,
            erc314TokenReserve,
            erc314NativeReserve
        );
    }

    // =============================================================
    // 十三、ERC314 流动性管理
    // =============================================================

    /// @notice 添加 ERC314 内置池子流动性
    /// @param tokenAmount 添加到 ERC314 池子的代币数量
    function addErc314Liquidity(uint256 tokenAmount)
        external
        payable
        onlyRole(LIQUIDITY_MANAGER_ROLE)
        nonReentrant
    {
        require(tokenAmount > 0, "token zero");
        require(msg.value > 0, "native zero");

        _spendAllowance(msg.sender, address(this), tokenAmount);

        _update(msg.sender, address(this), tokenAmount);

        erc314TokenReserve += tokenAmount;
        erc314NativeReserve += msg.value;

        emit Erc314LiquidityAdded(msg.sender, tokenAmount, msg.value);
    }

    /// @notice 移除 ERC314 内置池子流动性
    /// @param tokenAmount 移出的代币数量
    /// @param nativeAmount 移出的 ETH/BNB 数量
    /// @param to 接收代币和 ETH/BNB 的地址
    function removeErc314Liquidity(
        uint256 tokenAmount,
        uint256 nativeAmount,
        address payable to
    )
        external
        onlyRole(LIQUIDITY_MANAGER_ROLE)
        nonReentrant
        erc314SwapLock
    {
        require(to != address(0), "to zero");
        require(tokenAmount <= erc314TokenReserve, "token reserve low");
        require(nativeAmount <= erc314NativeReserve, "native reserve low");
        require(balanceOf(address(this)) >= tokenAmount, "token balance low");
        require(address(this).balance >= nativeAmount, "native balance low");

        erc314TokenReserve -= tokenAmount;
        erc314NativeReserve -= nativeAmount;

        if (tokenAmount > 0) {
            _update(address(this), to, tokenAmount);
        }

        if (nativeAmount > 0) {
            (bool ok, ) = to.call{value: nativeAmount}("");
            require(ok, "native transfer failed");
        }

        emit Erc314LiquidityRemoved(to, tokenAmount, nativeAmount);
    }

    /// @notice 手动同步 ERC314 储备
    /// @dev 单次同步偏差不能超过 5%，并且两次同步之间必须经过冷却时间
    /// @param tokenReserve 新的代币储备，不能超过合约真实代币余额
    /// @param nativeReserve 新的 ETH/BNB 储备，不能超过合约真实 ETH/BNB 余额
    function syncErc314Reserves(uint256 tokenReserve, uint256 nativeReserve)
        external
        onlyRole(LIQUIDITY_MANAGER_ROLE)
    {
        require(tokenReserve <= balanceOf(address(this)), "token reserve > balance");
        require(nativeReserve <= address(this).balance, "native reserve > balance");

        /*
            冷却限制：
            防止有人拿到 LIQUIDITY_MANAGER_ROLE 后，
            通过很多次 5% 的小幅同步，在短时间内把价格慢慢扭曲。
        */
        require(
            block.timestamp >= lastErc314ReserveSyncAt + erc314ReserveSyncCooldown,
            "reserve sync cooling down"
        );

        _requireReserveSyncDeviationSafe(erc314TokenReserve, tokenReserve);
        _requireReserveSyncDeviationSafe(erc314NativeReserve, nativeReserve);

        erc314TokenReserve = tokenReserve;
        erc314NativeReserve = nativeReserve;
        lastErc314ReserveSyncAt = block.timestamp;

        emit Erc314ReservesSynced(tokenReserve, nativeReserve);
    }

    /// @notice 检查新储备相对旧储备的偏差是否过大
    /// @param oldValue 旧储备
    /// @param newValue 新储备
    function _requireReserveSyncDeviationSafe(uint256 oldValue, uint256 newValue) internal pure {
        /*
            如果旧储备是 0，就不允许直接同步成正数。
            初始建池应该走 addErc314Liquidity()，
            不应该靠 syncErc314Reserves() 手动创造初始价格。
        */
        if (oldValue == 0) {
            require(newValue == 0, "old reserve zero");
            return;
        }

        uint256 diff = oldValue > newValue ? oldValue - newValue : newValue - oldValue;
        uint256 maxDiff = Math.mulDiv(oldValue, MAX_RESERVE_SYNC_DEVIATION_BPS, BPS_DENOMINATOR);

        require(diff <= maxDiff, "reserve sync deviation too high");
    }

    /// @notice 设置 ERC314 储备同步冷却时间
    /// @param newCooldown 新冷却时间，单位秒
    function setErc314ReserveSyncCooldown(uint256 newCooldown)
        external
        onlyRole(LIQUIDITY_MANAGER_ROLE)
    {
        require(newCooldown <= MAX_RESERVE_SYNC_COOLDOWN, "cooldown too long");

        uint256 oldCooldown = erc314ReserveSyncCooldown;

        erc314ReserveSyncCooldown = newCooldown;

        emit Erc314ReserveSyncCooldownUpdated(oldCooldown, newCooldown);
    }

    /// @notice 设置 ERC314 内置池子手续费
    /// @param feeBps 新手续费，单位 bps，例如 30 表示 0.3%，最高 1000 表示 10%
    function setErc314SwapFeeBps(uint256 feeBps) external onlyRole(LIQUIDITY_MANAGER_ROLE) {
        require(feeBps <= 1_000, "fee too high");

        uint256 oldFeeBps = erc314SwapFeeBps;

        erc314SwapFeeBps = feeBps;

        emit Erc314SwapFeeUpdated(oldFeeBps, feeBps);
    }

    // =============================================================
    // 十四、UniswapV2 / PancakeSwapV2 功能
    // =============================================================

    /// @notice 设置 Router，并自动创建或读取主交易对
    /// @param router_ Router 地址，例如 PancakeSwapV2 Router
    function setRouter(address router_) external onlyRole(LIQUIDITY_MANAGER_ROLE) {
        _setRouter(router_, false);
    }

    /// @notice 设置 Router，并可选择是否清理旧 mainPair 的 AMM 标记
    /// @param router_ Router 地址
    /// @param clearOldMainPair true 表示清理旧 mainPair 的 isAmmPair 标记
    function setRouter(address router_, bool clearOldMainPair)
        external
        onlyRole(LIQUIDITY_MANAGER_ROLE)
    {
        _setRouter(router_, clearOldMainPair);
    }

    /// @notice 内部设置 Router 方法
    /// @param router_ Router 地址
    /// @param clearOldMainPair 是否清理旧 mainPair 的 AMM 标记
    function _setRouter(address router_, bool clearOldMainPair) internal {
        require(router_ != address(0), "router zero");

        address oldMainPair = mainPair;

        router = IUniswapV2Router02(router_);

        address weth = router.WETH();
        address factory = router.factory();

        address pair = IUniswapV2Factory(factory).getPair(address(this), weth);

        if (pair == address(0)) {
            pair = IUniswapV2Factory(factory).createPair(address(this), weth);
        }

        mainPair = pair;
        isAmmPair[pair] = true;

        /*
            是否清理旧 Pair：
            - false：保留旧 Pair 的 AMM 标记，适合旧池仍然可交易的情况。
            - true：迁移到新 Router 后，不再把旧 Pair 当作 AMM 交易对。
        */
        if (
            clearOldMainPair &&
            oldMainPair != address(0) &&
            oldMainPair != pair
        ) {
            isAmmPair[oldMainPair] = false;
            emit AmmPairUpdated(oldMainPair, false);
        }

        emit RouterUpdated(router_);
        emit AmmPairUpdated(pair, true);
    }

    /// @notice 手动设置 AMM Pair 地址
    /// @param pair Pair 地址
    /// @param enabled 是否标记为 AMM Pair
    function setAmmPair(address pair, bool enabled) external onlyRole(LIQUIDITY_MANAGER_ROLE) {
        require(pair != address(0), "pair zero");

        isAmmPair[pair] = enabled;

        emit AmmPairUpdated(pair, enabled);
    }

    /// @notice 通过 Router 买入本代币
    /// @param amountOutMin 最少收到多少代币，滑点保护
    /// @param deadline 截止时间戳，超过就失败
    function uniswapBuyTokens(
        uint256 amountOutMin,
        uint256 deadline
    ) external payable nonReentrant {
        require(address(router) != address(0), "router not set");
        require(msg.value > 0, "native zero");

        if (!publicAmmSwapEnabled) {
            require(ammWhitelistBuy[msg.sender], "amm buy not whitelisted");
        }

        address[] memory path = new address[](2);
        path[0] = router.WETH();
        path[1] = address(this);

        router.swapExactETHForTokensSupportingFeeOnTransferTokens{value: msg.value}(
            amountOutMin,
            path,
            msg.sender,
            deadline
        );
    }

    /// @notice 通过 Router 卖出本代币
    /// @param tokenAmount 用户要卖出的代币数量
    /// @param amountOutMin 最少收到多少 ETH/BNB，滑点保护
    /// @param deadline 截止时间戳，超过就失败
    function uniswapSellTokens(
        uint256 tokenAmount,
        uint256 amountOutMin,
        uint256 deadline
    ) external nonReentrant {
        require(address(router) != address(0), "router not set");
        require(tokenAmount > 0, "token zero");

        if (!publicAmmSwapEnabled) {
            require(ammWhitelistSell[msg.sender], "amm sell not whitelisted");
        }

        _spendAllowance(msg.sender, address(this), tokenAmount);

        uint256 beforeContractBalance = balanceOf(address(this));

        _transferWithTax(msg.sender, address(this), tokenAmount, sellTaxBps, true);

        uint256 receivedAmount = balanceOf(address(this)) - beforeContractBalance;
        require(receivedAmount > 0, "received zero");

        _approve(address(this), address(router), receivedAmount);

        address[] memory path = new address[](2);
        path[0] = address(this);
        path[1] = router.WETH();

        router.swapExactTokensForETHSupportingFeeOnTransferTokens(
            receivedAmount,
            amountOutMin,
            path,
            msg.sender,
            deadline
        );
    }

    /// @notice 添加 UniswapV2 / PancakeSwapV2 的 Token + ETH/BNB 流动性
    /// @param tokenAmount 添加的代币数量
    /// @param amountTokenMin 最少实际加入多少代币，滑点保护
    /// @param amountETHMin 最少实际加入多少 ETH/BNB，滑点保护
    /// @param deadline 截止时间戳，超过就失败
    /// @return amountToken 实际加入的代币数量
    /// @return amountETH 实际加入的 ETH/BNB 数量
    /// @return liquidity 获得的 LP 数量
    function addUniswapLiquidityETH(
        uint256 tokenAmount,
        uint256 amountTokenMin,
        uint256 amountETHMin,
        uint256 deadline
    )
        external
        payable
        onlyRole(LIQUIDITY_MANAGER_ROLE)
        nonReentrant
        returns (
            uint256 amountToken,
            uint256 amountETH,
            uint256 liquidity
        )
    {
        require(address(router) != address(0), "router not set");
        require(tokenAmount > 0, "token zero");
        require(msg.value > 0, "native zero");

        _spendAllowance(msg.sender, address(this), tokenAmount);

        _update(msg.sender, address(this), tokenAmount);

        _approve(address(this), address(router), tokenAmount);

        return router.addLiquidityETH{value: msg.value}(
            address(this),
            tokenAmount,
            amountTokenMin,
            amountETHMin,
            msg.sender,
            deadline
        );
    }

    /// @notice 移除 UniswapV2 / PancakeSwapV2 的 Token + ETH/BNB 流动性
    /// @param liquidity 要移除的 LP 数量
    /// @param amountTokenMin 最少收到多少代币
    /// @param amountETHMin 最少收到多少 ETH/BNB
    /// @param deadline 截止时间戳，超过就失败
    /// @return amountETH 实际收到的 ETH/BNB 数量
    function removeUniswapLiquidityETH(
        uint256 liquidity,
        uint256 amountTokenMin,
        uint256 amountETHMin,
        uint256 deadline
    ) external onlyRole(LIQUIDITY_MANAGER_ROLE) nonReentrant returns (uint256 amountETH) {
        require(address(router) != address(0), "router not set");
        require(mainPair != address(0), "pair not set");
        require(liquidity > 0, "liquidity zero");

        IERC20(mainPair).safeTransferFrom(msg.sender, address(this), liquidity);

        IERC20(mainPair).forceApprove(address(router), liquidity);

        amountETH = router.removeLiquidityETHSupportingFeeOnTransferTokens(
            address(this),
            liquidity,
            amountTokenMin,
            amountETHMin,
            msg.sender,
            deadline
        );
    }

    // =============================================================
    // 十五、分红功能
    // =============================================================

    /// @notice 设置分红币
    /// @param rewardToken_ 新的分红币地址
    function setRewardToken(address rewardToken_) external onlyRole(DIVIDEND_MANAGER_ROLE) {
        require(rewardToken_ != address(0), "reward zero");
        require(rewardToken_ != address(this), "reward cannot self");

        address oldRewardToken = address(rewardToken);

        if (oldRewardToken != address(0) && oldRewardToken != rewardToken_) {
            uint256 oldRewardBalance = IERC20(oldRewardToken).balanceOf(address(this));
            require(oldRewardBalance == 0, "old reward balance not zero");
        }

        rewardToken = IERC20(rewardToken_);

        emit RewardTokenUpdated(rewardToken_);
    }

    /// @notice 设置单次最大分红数量
    /// @param newAmount 新的单次最大分红数量
    function setMaxDividendDistributionAmount(uint256 newAmount)
        external
        onlyRole(DIVIDEND_MANAGER_ROLE)
    {
        require(newAmount > 0, "max dividend zero");
        require(newAmount <= MAX_SAFE_DIVIDEND_DISTRIBUTION_AMOUNT, "max dividend too large");

        uint256 oldAmount = maxDividendDistributionAmount;

        maxDividendDistributionAmount = newAmount;

        emit MaxDividendDistributionAmountUpdated(oldAmount, newAmount);
    }

    /// @notice 发放分红
    /// @dev 使用实际到账数量发分红，兼容部分扣税型 rewardToken
    /// @param amount 本次准备转入的分红币数量
    function distributeDividends(uint256 amount)
        external
        onlyRole(DIVIDEND_MANAGER_ROLE)
        nonReentrant
    {
        require(address(rewardToken) != address(0), "reward not set");
        require(amount > 0, "amount zero");
        require(totalDividendShares > 0, "no dividend shares");

        uint256 beforeBalance = rewardToken.balanceOf(address(this));

        rewardToken.safeTransferFrom(msg.sender, address(this), amount);

        uint256 afterBalance = rewardToken.balanceOf(address(this));
        uint256 receivedAmount = afterBalance - beforeBalance;

        require(receivedAmount > 0, "reward received zero");
        require(receivedAmount <= maxDividendDistributionAmount, "dividend too large");

        uint256 increment = Math.mulDiv(receivedAmount, MAGNITUDE, totalDividendShares);

        magnifiedDividendPerShare += increment;
        totalDividendsDistributed += receivedAmount;

        emit DividendsDistributed(msg.sender, receivedAmount);
    }

    /// @notice 用户领取自己的分红
    function claimDividends() external nonReentrant {
        _claimDividends(msg.sender);
    }

    /// @notice 帮某个账户领取分红，分红仍然发给该账户
    /// @param account 要领取分红的账户
    function claimDividendsFor(address account) external nonReentrant {
        _claimDividends(account);
    }

    /// @notice 内部领取分红逻辑
    /// @param account 要领取分红的账户
    function _claimDividends(address account) internal {
        require(account != address(0), "account zero");
        require(address(rewardToken) != address(0), "reward not set");

        _settleDividend(account);
        _syncDividendShare(account);

        uint256 amount = pendingDividends[account];
        require(amount > 0, "no dividends");

        pendingDividends[account] = 0;
        totalDividendsClaimed += amount;

        rewardToken.safeTransfer(account, amount);

        emit DividendsClaimed(account, amount);
    }

    /// @notice 查询某个账户当前可领取分红
    /// @param account 查询账户
    /// @return 当前可领取分红数量
    function pendingDividendOf(address account) external view returns (uint256) {
        if (account == address(0) || isDividendExcluded[account]) {
            return 0;
        }

        uint256 shares = dividendShares[account];
        uint256 accumulated = Math.mulDiv(shares, magnifiedDividendPerShare, MAGNITUDE);

        if (accumulated < dividendDebt[account]) {
            return pendingDividends[account];
        }

        return pendingDividends[account] + accumulated - dividendDebt[account];
    }

    /// @notice 当前合约需要保留给用户领取的分红币数量
    /// @dev 等于累计发放分红 - 累计已领取分红
    /// @return 当前分红负债数量
    function reservedRewardBalance() public view returns (uint256) {
        return totalDividendsDistributed - totalDividendsClaimed;
    }

    /// @notice 当前可以救援的多余分红币数量
    /// @dev 只统计超过用户未领取分红负债之外的 rewardToken
    /// @return 可救援的 rewardToken 数量
    function rescueableRewardTokenAmount() public view returns (uint256) {
        if (address(rewardToken) == address(0)) {
            return 0;
        }

        uint256 rewardBalance = rewardToken.balanceOf(address(this));
        uint256 reservedReward = reservedRewardBalance();

        if (rewardBalance <= reservedReward) {
            return 0;
        }

        return rewardBalance - reservedReward;
    }

    /// @notice 设置某个账户是否排除分红
    /// @param account 账户地址
    /// @param excluded true 表示排除分红，false 表示参与分红
    function setDividendExcluded(address account, bool excluded)
        external
        onlyRole(DIVIDEND_MANAGER_ROLE)
    {
        require(account != address(0), "account zero");

        _setDividendExcluded(account, excluded);
    }

    /// @notice 内部设置是否排除分红
    /// @param account 账户地址
    /// @param excluded 是否排除分红
    function _setDividendExcluded(address account, bool excluded) internal {
        if (isDividendExcluded[account] == excluded) {
            return;
        }

        _settleDividend(account);

        isDividendExcluded[account] = excluded;

        _syncDividendShare(account);

        emit DividendExcludedUpdated(account, excluded);
    }

    /// @notice 把账户当前应得分红结算到 pendingDividends
    /// @param account 账户地址
    function _settleDividend(address account) internal {
        if (account == address(0) || isDividendExcluded[account]) {
            return;
        }

        uint256 shares = dividendShares[account];

        if (shares == 0) {
            dividendDebt[account] = 0;
            return;
        }

        uint256 accumulated = Math.mulDiv(shares, magnifiedDividendPerShare, MAGNITUDE);

        if (accumulated > dividendDebt[account]) {
            pendingDividends[account] += accumulated - dividendDebt[account];
        }

        dividendDebt[account] = accumulated;
    }

    /// @notice 同步账户分红份额
    /// @param account 账户地址
    function _syncDividendShare(address account) internal {
        if (account == address(0)) {
            return;
        }

        uint256 oldShares = dividendShares[account];
        uint256 newShares = isDividendExcluded[account] ? 0 : balanceOf(account);

        if (oldShares == newShares) {
            dividendDebt[account] = Math.mulDiv(newShares, magnifiedDividendPerShare, MAGNITUDE);
            return;
        }

        totalDividendShares = totalDividendShares - oldShares + newShares;
        dividendShares[account] = newShares;
        dividendDebt[account] = Math.mulDiv(newShares, magnifiedDividendPerShare, MAGNITUDE);
    }

    // =============================================================
    // 十六、管理员配置
    // =============================================================

    /// @notice 设置买税、卖税、转账税
    /// @param buyTaxBps_ 买入税，单位 bps，例如 300 表示 3%
    /// @param sellTaxBps_ 卖出税，单位 bps
    /// @param transferTaxBps_ 普通转账税，单位 bps
    function setTaxes(
        uint256 buyTaxBps_,
        uint256 sellTaxBps_,
        uint256 transferTaxBps_
    ) external onlyRole(TAX_MANAGER_ROLE) {
        require(buyTaxBps_ <= MAX_TAX_BPS, "buy tax too high");
        require(sellTaxBps_ <= MAX_TAX_BPS, "sell tax too high");
        require(transferTaxBps_ <= MAX_TAX_BPS, "transfer tax too high");

        buyTaxBps = buyTaxBps_;
        sellTaxBps = sellTaxBps_;
        transferTaxBps = transferTaxBps_;

        emit TaxesUpdated(buyTaxBps_, sellTaxBps_, transferTaxBps_);
    }

    /// @notice 设置新的收税钱包
    /// @param feeReceiver_ 新收税钱包地址，不能是合约自己
    function setFeeReceiver(address feeReceiver_) external onlyRole(TAX_MANAGER_ROLE) {
        require(feeReceiver_ != address(0), "feeReceiver zero");
        require(feeReceiver_ != address(this), "feeReceiver cannot be token");

        address oldFeeReceiver = feeReceiver;

        _settleDividend(oldFeeReceiver);
        _syncDividendShare(oldFeeReceiver);

        feeReceiver = feeReceiver_;

        isTaxExempt[feeReceiver_] = true;

        if (
            oldFeeReceiver != address(0) &&
            oldFeeReceiver != feeReceiver_ &&
            oldFeeReceiver != address(this) &&
            !hasRole(DEFAULT_ADMIN_ROLE, oldFeeReceiver)
        ) {
            isTaxExempt[oldFeeReceiver] = false;

            emit FeeReceiverTaxExemptCleared(oldFeeReceiver);
            emit TaxExemptUpdated(oldFeeReceiver, false);
        }

        _setDividendExcluded(feeReceiver_, true);

        emit FeeReceiverUpdated(feeReceiver_);
    }

    /// @notice 设置某个地址是否免税
    /// @param account 账户地址
    /// @param exempt true 表示免税，false 表示不免税
    function setTaxExempt(address account, bool exempt) external onlyRole(TAX_MANAGER_ROLE) {
        require(account != address(0), "account zero");

        isTaxExempt[account] = exempt;

        emit TaxExemptUpdated(account, exempt);
    }

    /// @notice 冻结或解冻某个账户
    /// @param account 账户地址
    /// @param frozen true 表示冻结，false 表示解冻
    function setFrozen(address account, bool frozen) external onlyRole(FREEZER_ROLE) {
        require(account != address(0), "account zero");
        require(account != address(this), "cannot freeze token");

        isFrozen[account] = frozen;

        emit Frozen(account, frozen);
    }

    /// @notice 批量冻结或解冻账户
    /// @param accounts 账户数组
    /// @param frozen true 表示冻结，false 表示解冻
    function batchSetFrozen(address[] calldata accounts, bool frozen)
        external
        onlyRole(FREEZER_ROLE)
    {
        require(accounts.length <= MAX_BATCH_SIZE, "batch too large");

        for (uint256 i = 0; i < accounts.length; i++) {
            require(accounts[i] != address(0), "account zero");
            require(accounts[i] != address(this), "cannot freeze token");

            isFrozen[accounts[i]] = frozen;

            emit Frozen(accounts[i], frozen);
        }
    }

    /// @notice 设置 ERC314 是否公开买卖
    /// @param enabled true 表示公开，false 表示只允许白名单
    function setPublicErc314SwapEnabled(bool enabled) external onlyRole(PAUSER_ROLE) {
        publicErc314SwapEnabled = enabled;

        emit PublicErc314SwapUpdated(enabled);
    }

    /// @notice 设置 AMM 是否公开买卖
    /// @param enabled true 表示公开，false 表示只允许白名单
    function setPublicAmmSwapEnabled(bool enabled) external onlyRole(PAUSER_ROLE) {
        publicAmmSwapEnabled = enabled;

        emit PublicAmmSwapUpdated(enabled);
    }

    /// @notice 设置是否允许 transfer(address(this), amount) 自动卖出
    /// @param enabled true 表示开启，false 表示关闭
    function setErc314SellByTransferEnabled(bool enabled) external onlyRole(PAUSER_ROLE) {
        erc314SellByTransferEnabled = enabled;

        emit Erc314SellByTransferUpdated(enabled);
    }

    /// @notice 设置 ERC314 买入白名单
    /// @param account 账户地址
    /// @param enabled true 表示加入白名单，false 表示移除
    function setErc314WhitelistBuy(address account, bool enabled)
        external
        onlyRole(WHITELIST_MANAGER_ROLE)
    {
        require(account != address(0), "account zero");

        erc314WhitelistBuy[account] = enabled;

        emit Erc314WhitelistBuyUpdated(account, enabled);
    }

    /// @notice 设置 ERC314 卖出白名单
    /// @param account 账户地址
    /// @param enabled true 表示加入白名单，false 表示移除
    function setErc314WhitelistSell(address account, bool enabled)
        external
        onlyRole(WHITELIST_MANAGER_ROLE)
    {
        require(account != address(0), "account zero");

        erc314WhitelistSell[account] = enabled;

        emit Erc314WhitelistSellUpdated(account, enabled);
    }

    /// @notice 设置 AMM 买入白名单
    /// @param account 账户地址
    /// @param enabled true 表示加入白名单，false 表示移除
    function setAmmWhitelistBuy(address account, bool enabled)
        external
        onlyRole(WHITELIST_MANAGER_ROLE)
    {
        require(account != address(0), "account zero");

        ammWhitelistBuy[account] = enabled;

        emit AmmWhitelistBuyUpdated(account, enabled);
    }

    /// @notice 设置 AMM 卖出白名单
    /// @param account 账户地址
    /// @param enabled true 表示加入白名单，false 表示移除
    function setAmmWhitelistSell(address account, bool enabled)
        external
        onlyRole(WHITELIST_MANAGER_ROLE)
    {
        require(account != address(0), "account zero");

        ammWhitelistSell[account] = enabled;

        emit AmmWhitelistSellUpdated(account, enabled);
    }

    /// @notice 批量设置 ERC314 买入白名单
    /// @param accounts 账户数组
    /// @param enabled true 表示加入白名单，false 表示移除
    function batchSetErc314WhitelistBuy(address[] calldata accounts, bool enabled)
        external
        onlyRole(WHITELIST_MANAGER_ROLE)
    {
        require(accounts.length <= MAX_BATCH_SIZE, "batch too large");

        for (uint256 i = 0; i < accounts.length; i++) {
            require(accounts[i] != address(0), "account zero");

            erc314WhitelistBuy[accounts[i]] = enabled;

            emit Erc314WhitelistBuyUpdated(accounts[i], enabled);
        }
    }

    /// @notice 批量设置 ERC314 卖出白名单
    /// @param accounts 账户数组
    /// @param enabled true 表示加入白名单，false 表示移除
    function batchSetErc314WhitelistSell(address[] calldata accounts, bool enabled)
        external
        onlyRole(WHITELIST_MANAGER_ROLE)
    {
        require(accounts.length <= MAX_BATCH_SIZE, "batch too large");

        for (uint256 i = 0; i < accounts.length; i++) {
            require(accounts[i] != address(0), "account zero");

            erc314WhitelistSell[accounts[i]] = enabled;

            emit Erc314WhitelistSellUpdated(accounts[i], enabled);
        }
    }

    /// @notice 批量设置 AMM 买入白名单
    /// @param accounts 账户数组
    /// @param enabled true 表示加入白名单，false 表示移除
    function batchSetAmmWhitelistBuy(address[] calldata accounts, bool enabled)
        external
        onlyRole(WHITELIST_MANAGER_ROLE)
    {
        require(accounts.length <= MAX_BATCH_SIZE, "batch too large");

        for (uint256 i = 0; i < accounts.length; i++) {
            require(accounts[i] != address(0), "account zero");

            ammWhitelistBuy[accounts[i]] = enabled;

            emit AmmWhitelistBuyUpdated(accounts[i], enabled);
        }
    }

    /// @notice 批量设置 AMM 卖出白名单
    /// @param accounts 账户数组
    /// @param enabled true 表示加入白名单，false 表示移除
    function batchSetAmmWhitelistSell(address[] calldata accounts, bool enabled)
        external
        onlyRole(WHITELIST_MANAGER_ROLE)
    {
        require(accounts.length <= MAX_BATCH_SIZE, "batch too large");

        for (uint256 i = 0; i < accounts.length; i++) {
            require(accounts[i] != address(0), "account zero");

            ammWhitelistSell[accounts[i]] = enabled;

            emit AmmWhitelistSellUpdated(accounts[i], enabled);
        }
    }

    /// @notice 暂停普通转账
    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    /// @notice 恢复普通转账
    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }

    /*
        权限丢弃说明：

        本合约继承了 OpenZeppelin AccessControl。
        所以不需要额外写 renounceMyRole 包装函数。

        用户想丢弃自己的权限，直接调用：
        renounceRole(role, msg.sender)

        例如：
        renounceRole(TAX_MANAGER_ROLE, msg.sender)
        renounceRole(PAUSER_ROLE, msg.sender)
        renounceRole(DEFAULT_ADMIN_ROLE, msg.sender)
    */

    // =============================================================
    // 十七、救援功能
    // =============================================================

    /// @notice 救援合约里多余的 ETH/BNB
    /// @param to 接收地址
    /// @param amount 提取数量
    function rescueETH(address payable to, uint256 amount)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
        nonReentrant
    {
        require(to != address(0), "to zero");

        uint256 balance = address(this).balance;
        uint256 available = balance > erc314NativeReserve ? balance - erc314NativeReserve : 0;

        require(amount <= available, "reserved native");

        (bool ok, ) = to.call{value: amount}("");
        require(ok, "eth transfer failed");

        emit RescueETH(to, amount);
    }

    /// @notice 救援误转进来的其他 ERC20 代币
    /// @dev 如果救援的是 rewardToken，只允许救援超过用户未领取分红之外的多余部分
    /// @param token 要救援的 ERC20 代币地址
    /// @param to 接收地址
    /// @param amount 救援数量
    function rescueToken(address token, address to, uint256 amount)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
        nonReentrant
    {
        require(token != address(0), "token zero");
        require(to != address(0), "to zero");

        // 不能提走本币，防止抽走 ERC314 储备币
        require(token != address(this), "cannot rescue self token");

        if (address(rewardToken) != address(0) && token == address(rewardToken)) {
            /*
                救援 rewardToken 时，只允许救援超额部分。

                必须保证：
                rewardToken.balanceOf(address(this)) >= reservedRewardBalance()

                也就是说：
                - 用户还没领取的分红不能被提走。
                - 管理员多转进来的 rewardToken 可以救援。
                - 用户误转进来的多余 rewardToken 可以救援。
            */
            uint256 rescueableReward = rescueableRewardTokenAmount();

            require(amount <= rescueableReward, "reserved reward");
        }

        IERC20(token).safeTransfer(to, amount);

        emit RescueToken(token, to, amount);
    }
}
