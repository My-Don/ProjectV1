// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IERC20Lite {
    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function allowance(address owner, address spender) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

interface IUniswapV2Factory {
    function getPair(address tokenA, address tokenB) external view returns (address pair);
    function createPair(address tokenA, address tokenB) external returns (address pair);
}

interface IUniswapV2Router02 {
    function factory() external pure returns (address);
    function WETH() external pure returns (address);

    function addLiquidityETH(
        address token,
        uint256 amountTokenDesired,
        uint256 amountTokenMin,
        uint256 amountETHMin,
        address to,
        uint256 deadline
    ) external payable returns (uint256 amountToken, uint256 amountETH, uint256 liquidity);

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
}

abstract contract OwnableLite {
    address private _owner;

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    constructor(address initialOwner) {
        require(initialOwner != address(0), "Owner: zero address");
        _transferOwnership(initialOwner);
    }

    function owner() public view returns (address) {
        return _owner;
    }

    modifier onlyOwner() {
        require(owner() == msg.sender, "Owner: caller is not owner");
        _;
    }

    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "Owner: zero address");
        _transferOwnership(newOwner);
    }

    function renounceOwnership() external onlyOwner {
        _transferOwnership(address(0));
    }

    function _transferOwnership(address newOwner) internal {
        address oldOwner = _owner;
        _owner = newOwner;
        emit OwnershipTransferred(oldOwner, newOwner);
    }
}

abstract contract ReentrancyGuardLite {
    uint256 private constant _NOT_ENTERED = 1;
    uint256 private constant _ENTERED = 2;
    uint256 private _status = _NOT_ENTERED;

    modifier nonReentrant() {
        require(_status != _ENTERED, "ReentrancyGuard: reentrant call");
        _status = _ENTERED;
        _;
        _status = _NOT_ENTERED;
    }
}

contract DividendDistributor {
    uint256 private constant ACCURACY = 1e36;

    address public immutable token;

    struct Share {
        uint256 amount;
        uint256 totalExcluded;
        uint256 totalRealised;
        uint256 unpaid;
    }

    mapping(address => Share) public shares;
    address[] public shareholders;
    mapping(address => uint256) public shareholderIndexes;
    mapping(address => bool) public shareholderExists;
    mapping(address => uint256) public shareholderClaims;

    uint256 public totalShares;
    uint256 public totalDividends;
    uint256 public totalDistributed;
    uint256 public dividendsPerShare;
    uint256 public minPeriod = 1 hours;
    uint256 public minDistribution = 0.001 ether;
    uint256 public currentIndex;
    uint256 public undistributedDividends;

    event DistributionCriteriaUpdated(uint256 minPeriod, uint256 minDistribution);
    event Deposit(uint256 amount, uint256 totalAllocated);
    event ShareUpdated(address indexed shareholder, uint256 previousAmount, uint256 newAmount);
    event DividendPaid(address indexed shareholder, uint256 amount);

    modifier onlyToken() {
        require(msg.sender == token, "Distributor: only token");
        _;
    }

    constructor(address token_) {
        require(token_ != address(0), "Distributor: zero token");
        token = token_;
    }

    receive() external payable {
        // ETH sent directly is kept until the token calls deposit(). Prefer token.depositETHDividends().
        undistributedDividends += msg.value;
    }

    function setDistributionCriteria(uint256 minPeriod_, uint256 minDistribution_) external onlyToken {
        minPeriod = minPeriod_;
        minDistribution = minDistribution_;
        emit DistributionCriteriaUpdated(minPeriod_, minDistribution_);
    }

    function setShare(address shareholder, uint256 amount) external onlyToken {
        if (shareholder == address(0)) return;

        Share storage share = shares[shareholder];
        uint256 previousAmount = share.amount;

        if (previousAmount > 0) {
            uint256 unpaidNow = _getUnpaidEarningsWithoutStored(shareholder);
            if (unpaidNow > 0) {
                share.unpaid += unpaidNow;
            }
        }

        if (amount > 0 && !shareholderExists[shareholder]) {
            _addShareholder(shareholder);
        } else if (amount == 0 && shareholderExists[shareholder]) {
            _removeShareholder(shareholder);
        }

        totalShares = totalShares - previousAmount + amount;
        share.amount = amount;
        share.totalExcluded = _getCumulativeDividends(amount);

        emit ShareUpdated(shareholder, previousAmount, amount);
    }

    function deposit() external payable onlyToken {
        uint256 amount = msg.value + undistributedDividends;
        if (amount == 0) return;

        if (totalShares == 0) {
            undistributedDividends = amount;
            emit Deposit(msg.value, 0);
            return;
        }

        undistributedDividends = 0;
        totalDividends += amount;
        dividendsPerShare += (amount * ACCURACY) / totalShares;
        emit Deposit(msg.value, amount);
    }

    function process(uint256 gas) external onlyToken returns (uint256 iterations, uint256 claims, uint256 lastProcessedIndex) {
        uint256 shareholderTotal = shareholders.length;
        if (shareholderTotal == 0) {
            return (0, 0, currentIndex);
        }

        uint256 gasUsed = 0;
        uint256 gasLeft = gasleft();

        while (gasUsed < gas && iterations < shareholderTotal) {
            if (currentIndex >= shareholderTotal) {
                currentIndex = 0;
            }

            address shareholder = shareholders[currentIndex];
            if (_shouldDistribute(shareholder)) {
                if (_distributeDividend(shareholder)) {
                    claims++;
                }
            }

            uint256 newGasLeft = gasleft();
            if (gasLeft > newGasLeft) {
                gasUsed += gasLeft - newGasLeft;
            }
            gasLeft = newGasLeft;
            currentIndex++;
            iterations++;
        }

        lastProcessedIndex = currentIndex;
    }

    function claim(address shareholder) external onlyToken returns (uint256 amount) {
        amount = _claim(shareholder);
    }

    function getUnpaidEarnings(address shareholder) public view returns (uint256) {
        Share storage share = shares[shareholder];
        return share.unpaid + _getUnpaidEarningsWithoutStored(shareholder);
    }

    function shareholderCount() external view returns (uint256) {
        return shareholders.length;
    }

    function _shouldDistribute(address shareholder) internal view returns (bool) {
        return shareholderClaims[shareholder] + minPeriod <= block.timestamp && getUnpaidEarnings(shareholder) >= minDistribution;
    }

    function _claim(address shareholder) internal returns (uint256 amount) {
        amount = getUnpaidEarnings(shareholder);
        if (amount == 0) return 0;

        Share storage share = shares[shareholder];
        share.unpaid = 0;
        share.totalExcluded = _getCumulativeDividends(share.amount);

        (bool success, ) = payable(shareholder).call{value: amount}("");
        if (!success) {
            share.unpaid = amount;
            return 0;
        }

        totalDistributed += amount;
        shareholderClaims[shareholder] = block.timestamp;
        share.totalRealised += amount;
        emit DividendPaid(shareholder, amount);
    }

    function _distributeDividend(address shareholder) internal returns (bool) {
        return _claim(shareholder) > 0;
    }

    function _getUnpaidEarningsWithoutStored(address shareholder) internal view returns (uint256) {
        Share storage share = shares[shareholder];
        if (share.amount == 0) return 0;

        uint256 cumulative = _getCumulativeDividends(share.amount);
        if (cumulative <= share.totalExcluded) return 0;
        return cumulative - share.totalExcluded;
    }

    function _getCumulativeDividends(uint256 share) internal view returns (uint256) {
        return (share * dividendsPerShare) / ACCURACY;
    }

    function _addShareholder(address shareholder) internal {
        shareholderIndexes[shareholder] = shareholders.length;
        shareholders.push(shareholder);
        shareholderExists[shareholder] = true;
    }

    function _removeShareholder(address shareholder) internal {
        uint256 index = shareholderIndexes[shareholder];
        address last = shareholders[shareholders.length - 1];

        shareholders[index] = last;
        shareholderIndexes[last] = index;
        shareholders.pop();

        shareholderExists[shareholder] = false;
        delete shareholderIndexes[shareholder];
    }
}

contract AdvancedReflectiveDividendToken is OwnableLite, ReentrancyGuardLite, IERC20Lite {
    uint256 private constant MAX = type(uint256).max;
    uint256 public constant BPS_DENOMINATOR = 10_000;
    uint16 public constant HARD_MAX_TOTAL_FEE_BPS = 2_000; // 20% absolute ceiling.

    string private _name;
    string private _symbol;
    uint8 private constant _DECIMALS = 18;

    uint256 private _tTotal;
    uint256 private _rTotal;
    uint256 private _tFeeTotal;

    mapping(address => uint256) private _rOwned;
    mapping(address => uint256) private _tOwned;
    mapping(address => mapping(address => uint256)) private _allowances;

    mapping(address => bool) private _isExcludedFromReflection;
    address[] private _excludedFromReflection;

    struct FeeRates {
        uint16 reflection;
        uint16 liquidity;
        uint16 dividend;
        uint16 treasury;
    }

    struct TransferValues {
        uint256 tTransferAmount;
        uint256 tReflection;
        uint256 tLiquidity;
        uint256 tDividend;
        uint256 tTreasury;
        uint256 tContract;
        uint256 rAmount;
        uint256 rTransferAmount;
        uint256 rReflection;
        uint256 rContract;
    }

    FeeRates public buyFees;
    FeeRates public sellFees;
    FeeRates public transferFees;
    uint16 public maxTotalFeeBps = 1_500; // Owner can only lower this ceiling.

    mapping(address => bool) public isFeeExempt;
    mapping(address => bool) public isFrozen;
    mapping(address => bool) public earlyBuyWhitelist;
    mapping(address => bool) public automatedMarketMakerPairs;
    mapping(address => bool) public isDividendExempt;

    bool public tradingEnabled;
    bool public whitelistBuyingEnabled;
    uint64 public whitelistBuyingEndsAt;
    bool public freezeFeatureLocked;

    IUniswapV2Router02 public uniswapV2Router;
    address public uniswapV2Pair;
    DividendDistributor public dividendDistributor;

    address public treasuryWallet;
    address public liquidityReceiver;

    uint256 public tokensForLiquidity;
    uint256 public tokensForDividends;
    uint256 public tokensForTreasury;
    uint256 public swapTokensAtAmount;
    uint256 public maxSwapTokensAtOnce;
    bool public swapEnabled = true;
    bool private swapping;

    uint256 public processDividendGas; // 0 disables automatic processing during transfers.
    uint256 public treasuryPendingETH;
    bool private processingDividends;

    event FeesUpdated(
        uint16 buyReflection,
        uint16 buyLiquidity,
        uint16 buyDividend,
        uint16 buyTreasury,
        uint16 sellReflection,
        uint16 sellLiquidity,
        uint16 sellDividend,
        uint16 sellTreasury,
        uint16 transferReflection,
        uint16 transferLiquidity,
        uint16 transferDividend,
        uint16 transferTreasury
    );
    event MaxTotalFeeBpsLowered(uint16 newMaxTotalFeeBps);
    event FeeExemptionUpdated(address indexed account, bool exempt);
    event FrozenUpdated(address indexed account, bool frozen);
    event FreezeFeatureLocked();
    event EarlyBuyWhitelistUpdated(address indexed account, bool allowed);
    event WhitelistBuyingConfigured(bool enabled, uint64 endsAt);
    event TradingEnabled(uint256 timestamp);
    event RouterUpdated(address indexed router, address indexed pair);
    event AutomatedMarketMakerPairUpdated(address indexed pair, bool enabled);
    event DividendExemptionUpdated(address indexed account, bool exempt);
    event ReflectionExclusionUpdated(address indexed account, bool excluded);
    event SwapSettingsUpdated(bool enabled, uint256 swapTokensAtAmount, uint256 maxSwapTokensAtOnce);
    event WalletsUpdated(address indexed treasuryWallet, address indexed liquidityReceiver);
    event SwapBack(uint256 tokensSwapped, uint256 ethReceived, uint256 ethToDividends, uint256 ethToTreasury, uint256 ethToLiquidity);
    event TreasuryETHPending(uint256 amount);
    event LiquidityAdded(uint256 tokenAmount, uint256 ethAmount);
    event ETHDividendsDeposited(uint256 amount);
    event DividendProcessed(uint256 iterations, uint256 claims, uint256 lastProcessedIndex);

    constructor(
        string memory name_,
        string memory symbol_,
        uint256 totalSupply_,
        address router_,
        address treasuryWallet_,
        address liquidityReceiver_
    ) OwnableLite(msg.sender) {
        require(totalSupply_ > 0, "Token: zero supply");
        require(treasuryWallet_ != address(0), "Token: zero treasury");
        require(liquidityReceiver_ != address(0), "Token: zero liquidity receiver");

        _name = name_;
        _symbol = symbol_;
        _tTotal = totalSupply_;
        _rTotal = MAX - (MAX % _tTotal);

        treasuryWallet = treasuryWallet_;
        liquidityReceiver = liquidityReceiver_;

        // Conservative defaults: buys/sells 7%, wallet transfers 1%.
        buyFees = FeeRates({reflection: 200, liquidity: 100, dividend: 200, treasury: 200});
        sellFees = FeeRates({reflection: 200, liquidity: 200, dividend: 300, treasury: 200});
        transferFees = FeeRates({reflection: 100, liquidity: 0, dividend: 0, treasury: 0});

        swapTokensAtAmount = totalSupply_ / 10_000; // 0.01% of supply.
        maxSwapTokensAtOnce = totalSupply_ / 1_000; // 0.1% of supply.

        dividendDistributor = new DividendDistributor(address(this));

        _rOwned[msg.sender] = _rTotal;

        isFeeExempt[msg.sender] = true;
        isFeeExempt[address(this)] = true;
        isFeeExempt[treasuryWallet_] = true;

        isDividendExempt[address(this)] = true;
        isDividendExempt[treasuryWallet_] = true;
        isDividendExempt[liquidityReceiver_] = true;

        _excludeFromReflectionInternal(address(this));
        _excludeFromReflectionInternal(treasuryWallet_);
        _excludeFromReflectionInternal(liquidityReceiver_);

        if (router_ != address(0)) {
            _setRouter(router_);
        }

        _setDividendShare(msg.sender);

        emit Transfer(address(0), msg.sender, _tTotal);
        _emitFeesUpdated();
        emit WalletsUpdated(treasuryWallet_, liquidityReceiver_);
    }

    receive() external payable {}

    function name() external view returns (string memory) {
        return _name;
    }

    function symbol() external view returns (string memory) {
        return _symbol;
    }

    function decimals() external pure returns (uint8) {
        return _DECIMALS;
    }

    function totalSupply() external view override returns (uint256) {
        return _tTotal;
    }

    function totalReflectionFees() external view returns (uint256) {
        return _tFeeTotal;
    }

    function balanceOf(address account) public view override returns (uint256) {
        if (_isExcludedFromReflection[account]) {
            return _tOwned[account];
        }
        return tokenFromReflection(_rOwned[account]);
    }

    function allowance(address owner_, address spender) external view override returns (uint256) {
        return _allowances[owner_][spender];
    }

    function transfer(address to, uint256 amount) external override returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function approve(address spender, uint256 amount) public override returns (bool) {
        _approve(msg.sender, spender, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external override returns (bool) {
        uint256 currentAllowance = _allowances[from][msg.sender];
        if (currentAllowance != type(uint256).max) {
            require(currentAllowance >= amount, "ERC20: insufficient allowance");
            _approve(from, msg.sender, currentAllowance - amount);
        }
        _transfer(from, to, amount);
        return true;
    }

    function increaseAllowance(address spender, uint256 addedValue) external returns (bool) {
        _approve(msg.sender, spender, _allowances[msg.sender][spender] + addedValue);
        return true;
    }

    function decreaseAllowance(address spender, uint256 subtractedValue) external returns (bool) {
        uint256 currentAllowance = _allowances[msg.sender][spender];
        require(currentAllowance >= subtractedValue, "ERC20: decreased below zero");
        _approve(msg.sender, spender, currentAllowance - subtractedValue);
        return true;
    }

    function tokenFromReflection(uint256 rAmount) public view returns (uint256) {
        require(rAmount <= _rTotal, "Token: reflection exceeds total");
        uint256 currentRate = _getRate();
        return rAmount / currentRate;
    }

    function isExcludedFromReflection(address account) external view returns (bool) {
        return _isExcludedFromReflection[account];
    }

    function excludedReflectionCount() external view returns (uint256) {
        return _excludedFromReflection.length;
    }

    function pendingDividend(address account) external view returns (uint256) {
        return dividendDistributor.getUnpaidEarnings(account);
    }

    function feeSum(FeeRates memory fees) public pure returns (uint16) {
        return fees.reflection + fees.liquidity + fees.dividend + fees.treasury;
    }

    function setFees(FeeRates calldata buy, FeeRates calldata sell, FeeRates calldata walletTransfer) external onlyOwner {
        _validateFees(buy);
        _validateFees(sell);
        _validateFees(walletTransfer);
        buyFees = buy;
        sellFees = sell;
        transferFees = walletTransfer;
        _emitFeesUpdated();
    }

    function lowerMaxTotalFeeBps(uint16 newMaxTotalFeeBps) external onlyOwner {
        require(newMaxTotalFeeBps <= maxTotalFeeBps, "Token: can only lower");
        require(newMaxTotalFeeBps <= HARD_MAX_TOTAL_FEE_BPS, "Token: above hard max");
        maxTotalFeeBps = newMaxTotalFeeBps;
        emit MaxTotalFeeBpsLowered(newMaxTotalFeeBps);
    }

    function setFeeExempt(address account, bool exempt) external onlyOwner {
        isFeeExempt[account] = exempt;
        emit FeeExemptionUpdated(account, exempt);
    }

    function setFrozen(address account, bool frozen) external onlyOwner {
        require(!freezeFeatureLocked, "Token: freeze locked");
        require(account != address(0), "Token: zero address");
        require(account != owner(), "Token: owner protected");
        require(account != address(this), "Token: contract protected");
        require(account != address(uniswapV2Router), "Token: router protected");
        require(!automatedMarketMakerPairs[account], "Token: pair protected");
        isFrozen[account] = frozen;
        emit FrozenUpdated(account, frozen);
    }

    function lockFreezeFeature() external onlyOwner {
        freezeFeatureLocked = true;
        emit FreezeFeatureLocked();
    }

    function setEarlyBuyWhitelist(address[] calldata accounts, bool allowed) external onlyOwner {
        for (uint256 i = 0; i < accounts.length; i++) {
            earlyBuyWhitelist[accounts[i]] = allowed;
            emit EarlyBuyWhitelistUpdated(accounts[i], allowed);
        }
    }

    function configureWhitelistBuying(bool enabled, uint64 endsAt) external onlyOwner {
        require(!enabled || endsAt == 0 || endsAt > block.timestamp, "Token: bad end time");
        whitelistBuyingEnabled = enabled;
        whitelistBuyingEndsAt = endsAt;
        emit WhitelistBuyingConfigured(enabled, endsAt);
    }

    function enableTrading() external onlyOwner {
        tradingEnabled = true;
        whitelistBuyingEnabled = false;
        emit TradingEnabled(block.timestamp);
    }

    function setRouter(address router_) external onlyOwner {
        _setRouter(router_);
    }

    function setAutomatedMarketMakerPair(address pair, bool enabled) external onlyOwner {
        require(pair != address(0), "Token: zero pair");
        _setAutomatedMarketMakerPair(pair, enabled);
    }

    function setDividendExempt(address account, bool exempt) external onlyOwner {
        isDividendExempt[account] = exempt;
        _setDividendShare(account);
        emit DividendExemptionUpdated(account, exempt);
    }

    function excludeFromReflection(address account) external onlyOwner {
        _excludeFromReflectionInternal(account);
    }

    function includeInReflection(address account) external onlyOwner {
        require(_isExcludedFromReflection[account], "Token: not excluded");

        for (uint256 i = 0; i < _excludedFromReflection.length; i++) {
            if (_excludedFromReflection[i] == account) {
                _excludedFromReflection[i] = _excludedFromReflection[_excludedFromReflection.length - 1];
                _excludedFromReflection.pop();
                break;
            }
        }

        _tOwned[account] = 0;
        _isExcludedFromReflection[account] = false;
        emit ReflectionExclusionUpdated(account, false);
    }

    function setSwapSettings(bool enabled, uint256 swapAtAmount, uint256 maxSwapAmount) external onlyOwner {
        swapEnabled = enabled;
        swapTokensAtAmount = swapAtAmount;
        maxSwapTokensAtOnce = maxSwapAmount;
        emit SwapSettingsUpdated(enabled, swapAtAmount, maxSwapAmount);
    }

    function setWallets(address treasuryWallet_, address liquidityReceiver_) external onlyOwner {
        require(treasuryWallet_ != address(0), "Token: zero treasury");
        require(liquidityReceiver_ != address(0), "Token: zero liquidity receiver");

        treasuryWallet = treasuryWallet_;
        liquidityReceiver = liquidityReceiver_;

        isFeeExempt[treasuryWallet_] = true;
        isDividendExempt[treasuryWallet_] = true;
        isDividendExempt[liquidityReceiver_] = true;

        if (!_isExcludedFromReflection[treasuryWallet_]) {
            _excludeFromReflectionInternal(treasuryWallet_);
        }
        if (!_isExcludedFromReflection[liquidityReceiver_]) {
            _excludeFromReflectionInternal(liquidityReceiver_);
        }

        _setDividendShare(treasuryWallet_);
        _setDividendShare(liquidityReceiver_);
        emit WalletsUpdated(treasuryWallet_, liquidityReceiver_);
    }

    function setDividendProcessingGas(uint256 gas_) external onlyOwner {
        require(gas_ <= 750_000, "Token: gas too high");
        processDividendGas = gas_;
    }

    function setDividendDistributionCriteria(uint256 minPeriod, uint256 minDistribution) external onlyOwner {
        dividendDistributor.setDistributionCriteria(minPeriod, minDistribution);
    }

    function depositETHDividends() external payable nonReentrant {
        require(msg.value > 0, "Token: zero ETH");
        dividendDistributor.deposit{value: msg.value}();
        emit ETHDividendsDeposited(msg.value);
    }

    function claimDividend() external nonReentrant returns (uint256 amount) {
        _setDividendShare(msg.sender);
        processingDividends = true;
        amount = dividendDistributor.claim(msg.sender);
        processingDividends = false;
    }

    function processDividends(uint256 gas_) external nonReentrant returns (uint256 iterations, uint256 claims, uint256 lastProcessedIndex) {
        processingDividends = true;
        (iterations, claims, lastProcessedIndex) = dividendDistributor.process(gas_);
        processingDividends = false;
        emit DividendProcessed(iterations, claims, lastProcessedIndex);
    }

    function syncDividendShare(address account) external {
        _setDividendShare(account);
    }

    function manualSwapBack(uint256 amount) external onlyOwner nonReentrant {
        _swapBack(amount);
    }

    function buyThroughContract(uint256 amountOutMin, uint256 deadline) external payable nonReentrant {
        require(msg.value > 0, "Token: zero ETH");
        require(address(uniswapV2Router) != address(0), "Token: router not set");
        require(deadline >= block.timestamp, "Token: expired");

        address[] memory path = new address[](2);
        path[0] = uniswapV2Router.WETH();
        path[1] = address(this);

        uniswapV2Router.swapExactETHForTokensSupportingFeeOnTransferTokens{value: msg.value}(
            amountOutMin,
            path,
            msg.sender,
            deadline
        );
    }

    function claimPendingTreasuryETH() external nonReentrant {
        require(msg.sender == treasuryWallet || msg.sender == owner(), "Token: not treasury");
        uint256 amount = treasuryPendingETH;
        require(amount > 0, "Token: no pending ETH");
        treasuryPendingETH = 0;
        _safeTransferETH(treasuryWallet, amount);
    }

    function rescueERC20(address token, address to, uint256 amount) external onlyOwner nonReentrant {
        require(token != address(this), "Token: cannot rescue native token");
        require(to != address(0), "Token: zero recipient");
        require(IERC20Lite(token).transfer(to, amount), "Token: rescue failed");
    }

    function rescueStuckETH(address to, uint256 amount) external onlyOwner nonReentrant {
        require(to != address(0), "Token: zero recipient");
        uint256 available = address(this).balance - treasuryPendingETH;
        require(amount <= available, "Token: amount reserved");
        _safeTransferETH(to, amount);
    }

    function _emitFeesUpdated() internal {
        emit FeesUpdated(
            buyFees.reflection,
            buyFees.liquidity,
            buyFees.dividend,
            buyFees.treasury,
            sellFees.reflection,
            sellFees.liquidity,
            sellFees.dividend,
            sellFees.treasury,
            transferFees.reflection,
            transferFees.liquidity,
            transferFees.dividend,
            transferFees.treasury
        );
    }

    function _approve(address owner_, address spender, uint256 amount) internal {
        require(owner_ != address(0), "ERC20: approve from zero");
        require(spender != address(0), "ERC20: approve to zero");
        _allowances[owner_][spender] = amount;
        emit Approval(owner_, spender, amount);
    }

    function _transfer(address sender, address recipient, uint256 amount) internal {
        require(!processingDividends, "Token: dividend callback locked");
        require(sender != address(0), "ERC20: transfer from zero");
        require(recipient != address(0), "ERC20: transfer to zero");
        require(amount > 0, "ERC20: zero amount");

        bool contractSwapTransfer = swapping && sender == address(this);

        if (!contractSwapTransfer) {
            require(!isFrozen[sender] && !isFrozen[recipient], "Token: frozen");
            _enforceTradingRules(sender, recipient);
        }

        if (
            !swapping &&
            swapEnabled &&
            automatedMarketMakerPairs[recipient] &&
            !isFeeExempt[sender] &&
            !isFeeExempt[recipient]
        ) {
            uint256 availableToSwap = tokensForLiquidity + tokensForDividends + tokensForTreasury;
            if (availableToSwap >= swapTokensAtAmount && swapTokensAtAmount > 0) {
                _swapBack(0);
            }
        }

        bool takeFee = !contractSwapTransfer && !isFeeExempt[sender] && !isFeeExempt[recipient];
        _tokenTransfer(sender, recipient, amount, takeFee);

        if (!swapping) {
            _setDividendShare(sender);
            _setDividendShare(recipient);

            if (processDividendGas > 0) {
                processingDividends = true;
                try dividendDistributor.process(processDividendGas) returns (uint256 iterations, uint256 claims, uint256 lastProcessedIndex) {
                    emit DividendProcessed(iterations, claims, lastProcessedIndex);
                } catch {}
                processingDividends = false;
            }
        }
    }

    function _tokenTransfer(address sender, address recipient, uint256 tAmount, bool takeFee) internal {
        FeeRates memory fees = takeFee ? _feeRatesFor(sender, recipient) : FeeRates(0, 0, 0, 0);
        TransferValues memory values = _getValues(tAmount, fees);

        if (_isExcludedFromReflection[sender]) {
            _tOwned[sender] -= tAmount;
        }
        if (_isExcludedFromReflection[recipient]) {
            _tOwned[recipient] += values.tTransferAmount;
        }

        _rOwned[sender] -= values.rAmount;
        _rOwned[recipient] += values.rTransferAmount;

        _takeContractFees(
            sender,
            values.tContract,
            values.rContract,
            values.tLiquidity,
            values.tDividend,
            values.tTreasury
        );

        _reflectFee(values.rReflection, values.tReflection);
        emit Transfer(sender, recipient, values.tTransferAmount);
    }

    function _getValues(uint256 tAmount, FeeRates memory fees) internal view returns (TransferValues memory values) {
        values.tReflection = (tAmount * fees.reflection) / BPS_DENOMINATOR;
        values.tLiquidity = (tAmount * fees.liquidity) / BPS_DENOMINATOR;
        values.tDividend = (tAmount * fees.dividend) / BPS_DENOMINATOR;
        values.tTreasury = (tAmount * fees.treasury) / BPS_DENOMINATOR;
        values.tContract = values.tLiquidity + values.tDividend + values.tTreasury;
        values.tTransferAmount = tAmount - values.tReflection - values.tContract;

        uint256 currentRate = _getRate();
        values.rAmount = tAmount * currentRate;
        values.rReflection = values.tReflection * currentRate;
        values.rContract = values.tContract * currentRate;
        values.rTransferAmount = values.rAmount - values.rReflection - values.rContract;
    }

    function _takeContractFees(
        address sender,
        uint256 tContract,
        uint256 rContract,
        uint256 tLiquidity,
        uint256 tDividend,
        uint256 tTreasury
    ) internal {
        if (tContract == 0) return;

        _rOwned[address(this)] += rContract;
        if (_isExcludedFromReflection[address(this)]) {
            _tOwned[address(this)] += tContract;
        }

        tokensForLiquidity += tLiquidity;
        tokensForDividends += tDividend;
        tokensForTreasury += tTreasury;

        emit Transfer(sender, address(this), tContract);
    }

    function _reflectFee(uint256 rReflection, uint256 tReflection) internal {
        if (rReflection == 0) return;
        _rTotal -= rReflection;
        _tFeeTotal += tReflection;
    }

    function _feeRatesFor(address sender, address recipient) internal view returns (FeeRates memory) {
        if (automatedMarketMakerPairs[sender]) {
            return buyFees;
        }
        if (automatedMarketMakerPairs[recipient]) {
            return sellFees;
        }
        return transferFees;
    }

    function _enforceTradingRules(address sender, address recipient) internal view {
        if (tradingEnabled || isFeeExempt[sender] || isFeeExempt[recipient]) {
            return;
        }

        if (automatedMarketMakerPairs[sender]) {
            bool withinWindow = whitelistBuyingEndsAt == 0 || block.timestamp <= whitelistBuyingEndsAt;
            require(whitelistBuyingEnabled && withinWindow && earlyBuyWhitelist[recipient], "Token: whitelist only");
            return;
        }

        revert("Token: trading disabled");
    }

    function _swapBack(uint256 requestedAmount) internal {
        if (swapping || address(uniswapV2Router) == address(0)) return;

        uint256 totalTokensToSwap = tokensForLiquidity + tokensForDividends + tokensForTreasury;
        if (totalTokensToSwap == 0) return;

        uint256 contractBalance = balanceOf(address(this));
        if (contractBalance == 0) return;

        uint256 amountToUse = requestedAmount == 0 ? totalTokensToSwap : requestedAmount;
        if (amountToUse > totalTokensToSwap) amountToUse = totalTokensToSwap;
        if (amountToUse > contractBalance) amountToUse = contractBalance;
        if (maxSwapTokensAtOnce > 0 && amountToUse > maxSwapTokensAtOnce) amountToUse = maxSwapTokensAtOnce;
        if (amountToUse == 0) return;

        uint256 liquidityTokens = (amountToUse * tokensForLiquidity) / totalTokensToSwap;
        uint256 dividendTokens = (amountToUse * tokensForDividends) / totalTokensToSwap;
        uint256 treasuryTokens = amountToUse - liquidityTokens - dividendTokens;

        if (liquidityTokens > tokensForLiquidity) liquidityTokens = tokensForLiquidity;
        if (dividendTokens > tokensForDividends) dividendTokens = tokensForDividends;
        if (treasuryTokens > tokensForTreasury) treasuryTokens = tokensForTreasury;

        uint256 liquidityHalf = liquidityTokens / 2;
        uint256 liquidityToSwap = liquidityTokens - liquidityHalf;
        uint256 tokensToSwap = liquidityToSwap + dividendTokens + treasuryTokens;
        if (tokensToSwap == 0) return;

        tokensForLiquidity -= liquidityTokens;
        tokensForDividends -= dividendTokens;
        tokensForTreasury -= treasuryTokens;

        swapping = true;

        uint256 ethBefore = address(this).balance;
        _swapTokensForETH(tokensToSwap);
        uint256 ethReceived = address(this).balance - ethBefore;

        uint256 ethForLiquidity = 0;
        uint256 ethForDividends = 0;
        uint256 ethForTreasury = ethReceived;

        if (ethReceived > 0) {
            ethForLiquidity = (ethReceived * liquidityToSwap) / tokensToSwap;
            ethForDividends = (ethReceived * dividendTokens) / tokensToSwap;
            ethForTreasury = ethReceived - ethForLiquidity - ethForDividends;
        }

        if (liquidityHalf > 0 && ethForLiquidity > 0) {
            _approve(address(this), address(uniswapV2Router), liquidityHalf);
            uniswapV2Router.addLiquidityETH{value: ethForLiquidity}(
                address(this),
                liquidityHalf,
                0,
                0,
                liquidityReceiver,
                block.timestamp
            );
            emit LiquidityAdded(liquidityHalf, ethForLiquidity);
        }

        if (ethForDividends > 0) {
            dividendDistributor.deposit{value: ethForDividends}();
            emit ETHDividendsDeposited(ethForDividends);
        }

        if (ethForTreasury > 0) {
            _sendTreasuryETH(ethForTreasury);
        }

        emit SwapBack(tokensToSwap, ethReceived, ethForDividends, ethForTreasury, ethForLiquidity);
        swapping = false;
    }

    function _swapTokensForETH(uint256 tokenAmount) internal {
        _approve(address(this), address(uniswapV2Router), tokenAmount);

        address[] memory path = new address[](2);
        path[0] = address(this);
        path[1] = uniswapV2Router.WETH();

        uniswapV2Router.swapExactTokensForETHSupportingFeeOnTransferTokens(
            tokenAmount,
            0,
            path,
            address(this),
            block.timestamp
        );
    }

    function _setRouter(address router_) internal {
        require(router_ != address(0), "Token: zero router");
        uniswapV2Router = IUniswapV2Router02(router_);

        address weth = uniswapV2Router.WETH();
        address factory = uniswapV2Router.factory();
        address pair = IUniswapV2Factory(factory).getPair(address(this), weth);
        if (pair == address(0)) {
            pair = IUniswapV2Factory(factory).createPair(address(this), weth);
        }
        uniswapV2Pair = pair;

        isFeeExempt[router_] = true;
        isDividendExempt[router_] = true;
        isDividendExempt[pair] = true;

        if (!_isExcludedFromReflection[router_]) {
            _excludeFromReflectionInternal(router_);
        }
        if (!_isExcludedFromReflection[pair]) {
            _excludeFromReflectionInternal(pair);
        }

        _setAutomatedMarketMakerPair(pair, true);
        _setDividendShare(router_);
        _setDividendShare(pair);

        emit RouterUpdated(router_, pair);
    }

    function _setAutomatedMarketMakerPair(address pair, bool enabled) internal {
        automatedMarketMakerPairs[pair] = enabled;
        if (enabled) {
            isDividendExempt[pair] = true;
            if (!_isExcludedFromReflection[pair]) {
                _excludeFromReflectionInternal(pair);
            }
            _setDividendShare(pair);
        }
        emit AutomatedMarketMakerPairUpdated(pair, enabled);
    }

    function _setDividendShare(address account) internal {
        if (account == address(0) || address(dividendDistributor) == address(0)) return;
        uint256 share = isDividendExempt[account] ? 0 : balanceOf(account);
        try dividendDistributor.setShare(account, share) {} catch {}
    }

    function _excludeFromReflectionInternal(address account) internal {
        require(account != address(0), "Token: zero address");
        if (_isExcludedFromReflection[account]) return;

        if (_rOwned[account] > 0) {
            _tOwned[account] = tokenFromReflection(_rOwned[account]);
        }
        _isExcludedFromReflection[account] = true;
        _excludedFromReflection.push(account);
        emit ReflectionExclusionUpdated(account, true);
    }

    function _getRate() internal view returns (uint256) {
        (uint256 rSupply, uint256 tSupply) = _getCurrentSupply();
        return rSupply / tSupply;
    }

    function _getCurrentSupply() internal view returns (uint256 rSupply, uint256 tSupply) {
        rSupply = _rTotal;
        tSupply = _tTotal;

        for (uint256 i = 0; i < _excludedFromReflection.length; i++) {
            address excluded = _excludedFromReflection[i];
            if (_rOwned[excluded] > rSupply || _tOwned[excluded] > tSupply) {
                return (_rTotal, _tTotal);
            }
            rSupply -= _rOwned[excluded];
            tSupply -= _tOwned[excluded];
        }

        if (rSupply < _rTotal / _tTotal || tSupply == 0) {
            return (_rTotal, _tTotal);
        }
    }

    function _validateFees(FeeRates memory fees) internal view {
        require(feeSum(fees) <= maxTotalFeeBps, "Token: fee too high");
        require(feeSum(fees) <= HARD_MAX_TOTAL_FEE_BPS, "Token: above hard max");
    }

    function _sendTreasuryETH(uint256 amount) internal {
        if (amount == 0) return;
        (bool success, ) = payable(treasuryWallet).call{value: amount}("");
        if (!success) {
            treasuryPendingETH += amount;
            emit TreasuryETHPending(amount);
        }
    }

    function _safeTransferETH(address to, uint256 amount) internal {
        if (amount == 0) return;
        require(to != address(0), "Token: zero recipient");
        (bool success, ) = payable(to).call{value: amount}("");
        require(success, "Token: ETH transfer failed");
    }
}