// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*
    依赖 OpenZeppelin 5.x：
    npm install @openzeppelin/contracts
*/

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

interface IUniswapV2Router02 {
    function WETH() external pure returns (address);

    function factory() external pure returns (address);

    function swapExactTokensForETHSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external;

    function swapExactETHForTokensSupportingFeeOnTransferTokens(
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external payable;

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

    function removeLiquidityETHSupportingFeeOnTransferTokens(
        address token,
        uint256 liquidity,
        uint256 amountTokenMin,
        uint256 amountETHMin,
        address to,
        uint256 deadline
    ) external returns (uint256 amountETH);
}

interface IUniswapV2Factory {
    function createPair(address tokenA, address tokenB) external returns (address pair);

    function getPair(address tokenA, address tokenB) external view returns (address pair);
}

contract AdvancedERC314DividendToken is ERC20, AccessControl, ReentrancyGuard, Pausable {
    // =========================
    // 一、权限角色
    // =========================

    // 税费管理员：可以设置买卖税、转账税、收税钱包
    bytes32 public constant TAX_MANAGER_ROLE = keccak256("TAX_MANAGER_ROLE");

    // 白名单管理员：可以设置谁能优先买、优先卖
    bytes32 public constant WHITELIST_MANAGER_ROLE = keccak256("WHITELIST_MANAGER_ROLE");

    // 冻结管理员：可以冻结/解冻账户
    bytes32 public constant FREEZER_ROLE = keccak256("FREEZER_ROLE");

    // 暂停管理员：可以暂停/恢复合约转账
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    // 分红管理员：可以设置分红参数、发放分红
    bytes32 public constant DIVIDEND_MANAGER_ROLE = keccak256("DIVIDEND_MANAGER_ROLE");

    // 流动性管理员：可以管理 ERC314 池子和 UniswapV2 流动性
    bytes32 public constant LIQUIDITY_MANAGER_ROLE = keccak256("LIQUIDITY_MANAGER_ROLE");

    // =========================
    // 二、基础参数
    // =========================

    // 最大税费，防止管理员把税设置得离谱
    uint256 public constant MAX_TAX_BPS = 2_000; // 20%

    // 手续费分母，10000 = 100%
    uint256 public constant BPS_DENOMINATOR = 10_000;

    // 收税钱包
    address public feeReceiver;

    // 买入税，单位 bps，例如 300 = 3%
    uint256 public buyTaxBps;

    // 卖出税，单位 bps
    uint256 public sellTaxBps;

    // 普通转账税，单位 bps
    uint256 public transferTaxBps;

    // 免税地址
    mapping(address => bool) public isTaxExempt;

    // 冻结地址
    mapping(address => bool) public isFrozen;

    // 自动做市商交易对地址，例如 PancakeSwap pair
    mapping(address => bool) public isAmmPair;

    // =========================
    // 三、白名单优先买卖
    // =========================

    // 公开 ERC314 买卖是否开启
    bool public publicErc314SwapEnabled;

    // 是否允许“转币到合约地址就卖出”
    bool public erc314SellByTransferEnabled;

    // 白名单买入地址
    mapping(address => bool) public whitelistBuy;

    // 白名单卖出/兑换地址
    mapping(address => bool) public whitelistSell;

    // =========================
    // 四、ERC314 风格池子参数
    // =========================

    /*
        ERC314 常见玩法：
        1. 用户直接给合约转 ETH/BNB，合约按内部池子价格给用户发币。
        2. 用户把代币转给合约，合约按内部池子价格给用户返 ETH/BNB。
        3. 内部价格使用 x * y = k 的 AMM 公式。
    */

    // ERC314 池子里的原生币储备，例如 ETH/BNB
    uint256 public erc314NativeReserve;

    // ERC314 池子里的代币储备
    uint256 public erc314TokenReserve;

    // ERC314 池子交易手续费，默认 30 = 0.3%
    uint256 public erc314SwapFeeBps = 30;

    // =========================
    // 五、UniswapV2 / PancakeSwapV2
    // =========================

    IUniswapV2Router02 public router;

    address public mainPair;

    // =========================
    // 六、分红参数
    // =========================

    /*
        这里使用“每股累计分红”的方式。
        好处：
        - 不需要循环所有持币人。
        - 用户自己 claim 分红。
        - 比直接遍历所有地址更安全。
    */

    IERC20 public rewardToken;

    uint256 private constant MAGNITUDE = 2 ** 128;

    // 每 1 个有效持仓累计可以分到多少奖励，放大 MAGNITUDE 倍，避免小数问题
    uint256 public magnifiedDividendPerShare;

    // 每个地址的有效分红持仓
    mapping(address => uint256) public dividendShares;

    // 每个地址已经记账过的分红债务
    mapping(address => uint256) public dividendDebt;

    // 每个地址尚未领取的分红
    mapping(address => uint256) public pendingDividends;

    // 总有效分红持仓
    uint256 public totalDividendShares;

    // 是否排除分红
    mapping(address => bool) public isDividendExcluded;

    // 累计发放分红数量
    uint256 public totalDividendsDistributed;

    // 累计领取分红数量
    uint256 public totalDividendsClaimed;

    // =========================
    // 七、事件
    // =========================

    event TaxesUpdated(uint256 buyTaxBps, uint256 sellTaxBps, uint256 transferTaxBps);
    event FeeReceiverUpdated(address indexed feeReceiver);

    event Frozen(address indexed account, bool frozen);
    event TaxExemptUpdated(address indexed account, bool exempt);

    event PublicErc314SwapUpdated(bool enabled);
    event Erc314SellByTransferUpdated(bool enabled);
    event WhitelistBuyUpdated(address indexed account, bool enabled);
    event WhitelistSellUpdated(address indexed account, bool enabled);

    event Erc314LiquidityAdded(address indexed provider, uint256 tokenAmount, uint256 nativeAmount);
    event Erc314LiquidityRemoved(address indexed receiver, uint256 tokenAmount, uint256 nativeAmount);
    event Erc314Buy(address indexed buyer, uint256 nativeIn, uint256 tokenOut);
    event Erc314Sell(address indexed seller, uint256 tokenIn, uint256 nativeOut);

    event RouterUpdated(address indexed router);
    event AmmPairUpdated(address indexed pair, bool enabled);

    event RewardTokenUpdated(address indexed rewardToken);
    event DividendExcludedUpdated(address indexed account, bool excluded);
    event DividendsDistributed(address indexed from, uint256 amount);
    event DividendsClaimed(address indexed account, uint256 amount);

    // =========================
    // 八、构造函数
    // =========================

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

        feeReceiver = feeReceiver_;

        // 给部署指定的 owner 分配所有权限
        _grantRole(DEFAULT_ADMIN_ROLE, owner_);
        _grantRole(TAX_MANAGER_ROLE, owner_);
        _grantRole(WHITELIST_MANAGER_ROLE, owner_);
        _grantRole(FREEZER_ROLE, owner_);
        _grantRole(PAUSER_ROLE, owner_);
        _grantRole(DIVIDEND_MANAGER_ROLE, owner_);
        _grantRole(LIQUIDITY_MANAGER_ROLE, owner_);

        // 铸造初始总量
        _mint(owner_, initialSupply_);

        // 默认部署者、合约自己、收税钱包免税
        isTaxExempt[owner_] = true;
        isTaxExempt[address(this)] = true;
        isTaxExempt[feeReceiver_] = true;

        // 默认合约自己、零地址、收税钱包不参与分红
        _setDividendExcluded(address(0), true);
        _setDividendExcluded(address(this), true);
        _setDividendExcluded(feeReceiver_, true);

        if (router_ != address(0)) {
            _setRouter(router_);
        }

        if (rewardToken_ != address(0)) {
            rewardToken = IERC20(rewardToken_);
            emit RewardTokenUpdated(rewardToken_);
        }

        // 默认关闭公开 ERC314 买卖，需要管理员开启
        publicErc314SwapEnabled = false;

        // 默认开启“转币到合约即卖出”
        erc314SellByTransferEnabled = true;
    }

    // =========================
    // 九、接收 ETH/BNB：ERC314 买入入口
    // =========================

    receive() external payable {
        _erc314Buy(msg.sender, msg.value);
    }

    // =========================
    // 十、ERC20 转账逻辑
    // =========================

    function transfer(address to, uint256 amount) public override returns (bool) {
        address from = _msgSender();

        // 如果用户把币转给合约，并且开启了 ERC314 转账卖出，那就执行卖出逻辑
        if (to == address(this) && erc314SellByTransferEnabled) {
            _erc314Sell(from, amount);
            return true;
        }

        uint256 taxBps = _getTransferTaxBps(from, to);
        _transferWithTax(from, to, amount, taxBps);

        return true;
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        address spender = _msgSender();

        _spendAllowance(from, spender, amount);

        // 如果授权转账的目标是合约，也允许按 ERC314 逻辑卖出
        if (to == address(this) && erc314SellByTransferEnabled) {
            _erc314Sell(from, amount);
            return true;
        }

        uint256 taxBps = _getTransferTaxBps(from, to);
        _transferWithTax(from, to, amount, taxBps);

        return true;
    }

    function _update(address from, address to, uint256 value) internal override {
        // 全局暂停后，普通转账不能走；铸币/销毁不拦截
        if (from != address(0) && to != address(0)) {
            require(!paused(), "token paused");
        }

        // 冻结地址不能转出，也不能接收
        if (from != address(0)) {
            require(!isFrozen[from], "from frozen");
        }

        if (to != address(0)) {
            require(!isFrozen[to], "to frozen");
        }

        // 转账前，先把双方分红结算到 pending
        if (from != address(0)) {
            _updateDividendShare(from);
        }

        if (to != address(0)) {
            _updateDividendShare(to);
        }

        super._update(from, to, value);

        // 转账后，再同步双方新的分红持仓
        if (from != address(0)) {
            _updateDividendShare(from);
        }

        if (to != address(0)) {
            _updateDividendShare(to);
        }
    }

    function _transferWithTax(address from, address to, uint256 amount, uint256 taxBps) internal {
        require(from != address(0), "from zero");
        require(to != address(0), "to zero");
        require(amount > 0, "amount zero");

        // 白名单阶段：如果是 AMM 买卖，公开未开启时，只允许白名单操作
        if (!publicErc314SwapEnabled && _isSwapWithAmm(from, to)) {
            if (isAmmPair[from]) {
                require(whitelistBuy[to], "buy not whitelisted");
            }

            if (isAmmPair[to]) {
                require(whitelistSell[from], "sell not whitelisted");
            }
        }

        if (isTaxExempt[from] || isTaxExempt[to] || taxBps == 0) {
            super._update(from, to, amount);
            return;
        }

        uint256 fee = (amount * taxBps) / BPS_DENOMINATOR;
        uint256 sendAmount = amount - fee;

        if (fee > 0) {
            super._update(from, feeReceiver, fee);
        }

        super._update(from, to, sendAmount);
    }

    function _getTransferTaxBps(address from, address to) internal view returns (uint256) {
        // 从 AMM pair 转出，通常代表用户买入
        if (isAmmPair[from]) {
            return buyTaxBps;
        }

        // 转入 AMM pair，通常代表用户卖出
        if (isAmmPair[to]) {
            return sellTaxBps;
        }

        // 普通钱包转账
        return transferTaxBps;
    }

    function _isSwapWithAmm(address from, address to) internal view returns (bool) {
        return isAmmPair[from] || isAmmPair[to];
    }

    // =========================
    // 十一、ERC314 买入 / 卖出
    // =========================

    function erc314Buy() external payable nonReentrant {
        _erc314Buy(msg.sender, msg.value);
    }

    function erc314Sell(uint256 tokenAmount) external nonReentrant {
        _erc314Sell(msg.sender, tokenAmount);
    }

    function _erc314Buy(address buyer, uint256 nativeAmount) internal nonReentrant {
        require(buyer != address(0), "buyer zero");
        require(nativeAmount > 0, "native zero");
        require(erc314NativeReserve > 0 && erc314TokenReserve > 0, "erc314 pool empty");

        if (!publicErc314SwapEnabled) {
            require(whitelistBuy[buyer], "buy not whitelisted");
        }

        uint256 tokenOut = getErc314AmountOut(
            nativeAmount,
            erc314NativeReserve,
            erc314TokenReserve
        );

        require(tokenOut > 0, "tokenOut zero");
        require(tokenOut < erc314TokenReserve, "insufficient token reserve");

        // 先更新池子储备
        erc314NativeReserve += nativeAmount;
        erc314TokenReserve -= tokenOut;

        // 合约给用户发币，买入税从 tokenOut 里扣
        _transferWithTax(address(this), buyer, tokenOut, buyTaxBps);

        emit Erc314Buy(buyer, nativeAmount, tokenOut);
    }

    function _erc314Sell(address seller, uint256 tokenAmount) internal nonReentrant {
        require(seller != address(0), "seller zero");
        require(tokenAmount > 0, "token zero");
        require(erc314NativeReserve > 0 && erc314TokenReserve > 0, "erc314 pool empty");

        if (!publicErc314SwapEnabled) {
            require(whitelistSell[seller], "sell not whitelisted");
        }

        uint256 beforeBalance = balanceOf(address(this));

        // 用户把币转给合约，卖出税从 tokenAmount 里扣
        _transferWithTax(seller, address(this), tokenAmount, sellTaxBps);

        uint256 receivedToken = balanceOf(address(this)) - beforeBalance;
        require(receivedToken > 0, "received zero");

        uint256 nativeOut = getErc314AmountOut(
            receivedToken,
            erc314TokenReserve,
            erc314NativeReserve
        );

        require(nativeOut > 0, "nativeOut zero");
        require(nativeOut < erc314NativeReserve, "insufficient native reserve");
        require(address(this).balance >= nativeOut, "native balance low");

        // 更新池子储备
        erc314TokenReserve += receivedToken;
        erc314NativeReserve -= nativeOut;

        (bool ok, ) = payable(seller).call{value: nativeOut}("");
        require(ok, "native transfer failed");

        emit Erc314Sell(seller, receivedToken, nativeOut);
    }

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

    function previewErc314Buy(uint256 nativeAmount) external view returns (uint256 tokenOut) {
        return getErc314AmountOut(nativeAmount, erc314NativeReserve, erc314TokenReserve);
    }

    function previewErc314Sell(uint256 tokenAmount) external view returns (uint256 nativeOut) {
        return getErc314AmountOut(tokenAmount, erc314TokenReserve, erc314NativeReserve);
    }

    // =========================
    // 十二、ERC314 流动性管理
    // =========================

    function addErc314Liquidity(uint256 tokenAmount) external payable onlyRole(LIQUIDITY_MANAGER_ROLE) nonReentrant {
        require(tokenAmount > 0, "token zero");
        require(msg.value > 0, "native zero");

        _spendAllowance(msg.sender, address(this), tokenAmount);

        // 管理员把自己的币转进合约，作为 ERC314 内部池子储备
        super._update(msg.sender, address(this), tokenAmount);

        erc314TokenReserve += tokenAmount;
        erc314NativeReserve += msg.value;

        emit Erc314LiquidityAdded(msg.sender, tokenAmount, msg.value);
    }

    function removeErc314Liquidity(
        uint256 tokenAmount,
        uint256 nativeAmount,
        address payable to
    ) external onlyRole(LIQUIDITY_MANAGER_ROLE) nonReentrant {
        require(to != address(0), "to zero");
        require(tokenAmount <= erc314TokenReserve, "token reserve low");
        require(nativeAmount <= erc314NativeReserve, "native reserve low");
        require(balanceOf(address(this)) >= tokenAmount, "token balance low");
        require(address(this).balance >= nativeAmount, "native balance low");

        erc314TokenReserve -= tokenAmount;
        erc314NativeReserve -= nativeAmount;

        if (tokenAmount > 0) {
            super._update(address(this), to, tokenAmount);
        }

        if (nativeAmount > 0) {
            (bool ok, ) = to.call{value: nativeAmount}("");
            require(ok, "native transfer failed");
        }

        emit Erc314LiquidityRemoved(to, tokenAmount, nativeAmount);
    }

    function syncErc314Reserves(uint256 tokenReserve, uint256 nativeReserve) external onlyRole(LIQUIDITY_MANAGER_ROLE) {
        require(tokenReserve <= balanceOf(address(this)), "token reserve > balance");
        require(nativeReserve <= address(this).balance, "native reserve > balance");

        erc314TokenReserve = tokenReserve;
        erc314NativeReserve = nativeReserve;
    }

    function setErc314SwapFeeBps(uint256 feeBps) external onlyRole(LIQUIDITY_MANAGER_ROLE) {
        require(feeBps <= 1_000, "fee too high"); // 最高 10%
        erc314SwapFeeBps = feeBps;
    }

    // =========================
    // 十三、UniswapV2 / PancakeSwapV2 兑换和流动性
    // =========================

    function setRouter(address router_) external onlyRole(LIQUIDITY_MANAGER_ROLE) {
        _setRouter(router_);
    }

    function _setRouter(address router_) internal {
        require(router_ != address(0), "router zero");

        router = IUniswapV2Router02(router_);

        address weth = router.WETH();
        address factory = router.factory();

        address pair = IUniswapV2Factory(factory).getPair(address(this), weth);

        if (pair == address(0)) {
            pair = IUniswapV2Factory(factory).createPair(address(this), weth);
        }

        mainPair = pair;
        isAmmPair[pair] = true;

        emit RouterUpdated(router_);
        emit AmmPairUpdated(pair, true);
    }

    function setAmmPair(address pair, bool enabled) external onlyRole(LIQUIDITY_MANAGER_ROLE) {
        require(pair != address(0), "pair zero");
        isAmmPair[pair] = enabled;

        emit AmmPairUpdated(pair, enabled);
    }

    function uniswapBuyTokens(
        uint256 amountOutMin,
        uint256 deadline
    ) external payable nonReentrant {
        require(address(router) != address(0), "router not set");
        require(msg.value > 0, "native zero");

        if (!publicErc314SwapEnabled) {
            require(whitelistBuy[msg.sender], "buy not whitelisted");
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

    function uniswapSellTokens(
        uint256 tokenAmount,
        uint256 amountOutMin,
        uint256 deadline
    ) external nonReentrant {
        require(address(router) != address(0), "router not set");
        require(tokenAmount > 0, "token zero");

        if (!publicErc314SwapEnabled) {
            require(whitelistSell[msg.sender], "sell not whitelisted");
        }

        _spendAllowance(msg.sender, address(this), tokenAmount);

        // 用户先把币转到本合约
        _transferWithTax(msg.sender, address(this), tokenAmount, sellTaxBps);

        // 本合约授权 router 卖币
        _approve(address(this), address(router), tokenAmount);

        address[] memory path = new address[](2);
        path[0] = address(this);
        path[1] = router.WETH();

        router.swapExactTokensForETHSupportingFeeOnTransferTokens(
            balanceOf(address(this)),
            amountOutMin,
            path,
            msg.sender,
            deadline
        );
    }

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

        // 管理员把币转进合约
        super._update(msg.sender, address(this), tokenAmount);

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

    function removeUniswapLiquidityETH(
        uint256 liquidity,
        uint256 amountTokenMin,
        uint256 amountETHMin,
        uint256 deadline
    ) external onlyRole(LIQUIDITY_MANAGER_ROLE) nonReentrant returns (uint256 amountETH) {
        require(address(router) != address(0), "router not set");
        require(mainPair != address(0), "pair not set");
        require(liquidity > 0, "liquidity zero");

        IERC20(mainPair).transferFrom(msg.sender, address(this), liquidity);
        IERC20(mainPair).approve(address(router), liquidity);

        amountETH = router.removeLiquidityETHSupportingFeeOnTransferTokens(
            address(this),
            liquidity,
            amountTokenMin,
            amountETHMin,
            msg.sender,
            deadline
        );
    }

    // =========================
    // 十四、分红功能
    // =========================

    function setRewardToken(address rewardToken_) external onlyRole(DIVIDEND_MANAGER_ROLE) {
        require(rewardToken_ != address(0), "reward zero");
        rewardToken = IERC20(rewardToken_);

        emit RewardTokenUpdated(rewardToken_);
    }

    function distributeDividends(uint256 amount) external onlyRole(DIVIDEND_MANAGER_ROLE) nonReentrant {
        require(address(rewardToken) != address(0), "reward not set");
        require(amount > 0, "amount zero");
        require(totalDividendShares > 0, "no dividend shares");

        bool ok = rewardToken.transferFrom(msg.sender, address(this), amount);
        require(ok, "reward transferFrom failed");

        magnifiedDividendPerShare += (amount * MAGNITUDE) / totalDividendShares;
        totalDividendsDistributed += amount;

        emit DividendsDistributed(msg.sender, amount);
    }

    function claimDividends() external nonReentrant {
        _claimDividends(msg.sender);
    }

    function claimDividendsFor(address account) external nonReentrant {
        _claimDividends(account);
    }

    function _claimDividends(address account) internal {
        require(address(rewardToken) != address(0), "reward not set");

        _updateDividendShare(account);

        uint256 amount = pendingDividends[account];
        require(amount > 0, "no dividends");

        pendingDividends[account] = 0;
        totalDividendsClaimed += amount;

        bool ok = rewardToken.transfer(account, amount);
        require(ok, "reward transfer failed");

        emit DividendsClaimed(account, amount);
    }

    function pendingDividendOf(address account) external view returns (uint256) {
        if (isDividendExcluded[account]) {
            return 0;
        }

        uint256 shares = dividendShares[account];
        uint256 accumulated = (shares * magnifiedDividendPerShare) / MAGNITUDE;

        if (accumulated < dividendDebt[account]) {
            return pendingDividends[account];
        }

        return pendingDividends[account] + accumulated - dividendDebt[account];
    }

    function setDividendExcluded(address account, bool excluded) external onlyRole(DIVIDEND_MANAGER_ROLE) {
        _setDividendExcluded(account, excluded);
    }

    function _setDividendExcluded(address account, bool excluded) internal {
        if (isDividendExcluded[account] == excluded) {
            return;
        }

        _updateDividendShare(account);

        isDividendExcluded[account] = excluded;

        _updateDividendShare(account);

        emit DividendExcludedUpdated(account, excluded);
    }

    function _updateDividendShare(address account) internal {
        if (account == address(0)) {
            return;
        }

        uint256 oldShares = dividendShares[account];

        if (oldShares > 0) {
            uint256 accumulated = (oldShares * magnifiedDividendPerShare) / MAGNITUDE;

            if (accumulated > dividendDebt[account]) {
                pendingDividends[account] += accumulated - dividendDebt[account];
            }
        }

        uint256 newShares = isDividendExcluded[account] ? 0 : balanceOf(account);

        if (newShares != oldShares) {
            totalDividendShares = totalDividendShares - oldShares + newShares;
            dividendShares[account] = newShares;
        }

        dividendDebt[account] = (newShares * magnifiedDividendPerShare) / MAGNITUDE;
    }

    // =========================
    // 十五、管理员配置
    // =========================

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

    function setFeeReceiver(address feeReceiver_) external onlyRole(TAX_MANAGER_ROLE) {
        require(feeReceiver_ != address(0), "feeReceiver zero");

        feeReceiver = feeReceiver_;
        isTaxExempt[feeReceiver_] = true;

        emit FeeReceiverUpdated(feeReceiver_);
    }

    function setTaxExempt(address account, bool exempt) external onlyRole(TAX_MANAGER_ROLE) {
        require(account != address(0), "account zero");

        isTaxExempt[account] = exempt;

        emit TaxExemptUpdated(account, exempt);
    }

    function setFrozen(address account, bool frozen) external onlyRole(FREEZER_ROLE) {
        require(account != address(0), "account zero");

        isFrozen[account] = frozen;

        emit Frozen(account, frozen);
    }

    function batchSetFrozen(address[] calldata accounts, bool frozen) external onlyRole(FREEZER_ROLE) {
        for (uint256 i = 0; i < accounts.length; i++) {
            require(accounts[i] != address(0), "account zero");

            isFrozen[accounts[i]] = frozen;

            emit Frozen(accounts[i], frozen);
        }
    }

    function setPublicErc314SwapEnabled(bool enabled) external onlyRole(PAUSER_ROLE) {
        publicErc314SwapEnabled = enabled;

        emit PublicErc314SwapUpdated(enabled);
    }

    function setErc314SellByTransferEnabled(bool enabled) external onlyRole(PAUSER_ROLE) {
        erc314SellByTransferEnabled = enabled;

        emit Erc314SellByTransferUpdated(enabled);
    }

    function setWhitelistBuy(address account, bool enabled) external onlyRole(WHITELIST_MANAGER_ROLE) {
        require(account != address(0), "account zero");

        whitelistBuy[account] = enabled;

        emit WhitelistBuyUpdated(account, enabled);
    }

    function setWhitelistSell(address account, bool enabled) external onlyRole(WHITELIST_MANAGER_ROLE) {
        require(account != address(0), "account zero");

        whitelistSell[account] = enabled;

        emit WhitelistSellUpdated(account, enabled);
    }

    function batchSetWhitelistBuy(address[] calldata accounts, bool enabled) external onlyRole(WHITELIST_MANAGER_ROLE) {
        for (uint256 i = 0; i < accounts.length; i++) {
            require(accounts[i] != address(0), "account zero");

            whitelistBuy[accounts[i]] = enabled;

            emit WhitelistBuyUpdated(accounts[i], enabled);
        }
    }

    function batchSetWhitelistSell(address[] calldata accounts, bool enabled) external onlyRole(WHITELIST_MANAGER_ROLE) {
        for (uint256 i = 0; i < accounts.length; i++) {
            require(accounts[i] != address(0), "account zero");

            whitelistSell[accounts[i]] = enabled;

            emit WhitelistSellUpdated(accounts[i], enabled);
        }
    }

    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }

    // =========================
    // 十六、权限丢弃
    // =========================

    function renounceMyRole(bytes32 role) external {
        renounceRole(role, msg.sender);
    }

    function renounceMyAdminRole() external {
        renounceRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }

    function renounceMyTaxManagerRole() external {
        renounceRole(TAX_MANAGER_ROLE, msg.sender);
    }

    function renounceMyWhitelistManagerRole() external {
        renounceRole(WHITELIST_MANAGER_ROLE, msg.sender);
    }

    function renounceMyFreezerRole() external {
        renounceRole(FREEZER_ROLE, msg.sender);
    }

    function renounceMyPauserRole() external {
        renounceRole(PAUSER_ROLE, msg.sender);
    }

    function renounceMyDividendManagerRole() external {
        renounceRole(DIVIDEND_MANAGER_ROLE, msg.sender);
    }

    function renounceMyLiquidityManagerRole() external {
        renounceRole(LIQUIDITY_MANAGER_ROLE, msg.sender);
    }

    // =========================
    // 十七、救援功能
    // =========================

    function rescueETH(address payable to, uint256 amount) external onlyRole(DEFAULT_ADMIN_ROLE) nonReentrant {
        require(to != address(0), "to zero");
        require(amount <= address(this).balance - erc314NativeReserve, "reserved native");

        (bool ok, ) = to.call{value: amount}("");
        require(ok, "eth transfer failed");
    }

    function rescueToken(address token, address to, uint256 amount) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(token != address(this), "cannot rescue self token");
        require(to != address(0), "to zero");

        bool ok = IERC20(token).transfer(to, amount);
        require(ok, "token transfer failed");
    }
}
