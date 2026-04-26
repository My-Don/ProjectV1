// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ERC165} from "@openzeppelin/contracts/utils/introspection/ERC165.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IERC1363Receiver} from "@openzeppelin/contracts/interfaces/IERC1363Receiver.sol";
import {IERC1363Spender} from "@openzeppelin/contracts/interfaces/IERC1363Spender.sol";

import {AutomationCompatibleInterface} from "@chainlink/contracts/src/v0.8/automation/AutomationCompatible.sol";

/**
 * @title StakeMint
 * @notice ERC1363 一步质押挖矿合约，集成 Chainlink Automation 快照。
 *
 * 质押方式：
 * 1. USDT.transferAndCall(address(this), amount)
 * 2. USDT.approveAndCall(address(this), amount)
 *
 * 生产安全策略：
 * - 不支持传统 approve + 手动 transferFrom 质押。
 * - 未质押不产生基础算力，避免零成本 Sybil 挖矿。
 * - 奖励按秒记账，但仍保留 24 小时领取间隔。
 * - GBC 余额不足时，用户领取奖励会失败，但不影响赎回 USDT 本金。
 * - owner 不能救援用户质押本金，只能救援 USDT 超额余额或非保护 token。
 */
contract StakeMint is
    Ownable2Step,
    ReentrancyGuard,
    Pausable,
    ERC165,
    AutomationCompatibleInterface,
    IERC1363Receiver,
    IERC1363Spender
{
    using SafeERC20 for IERC20;

    // ============ Errors ============

    error OnlyUSDTAllowed(address caller);
    error InvalidStakeAmount(uint256 amount);
    error InvalidWithdrawAmount(uint256 amount);
    error InvalidAmount(uint256 amount);
    error MiningNotStarted(address user);
    error MiningAlreadyStarted(address user);
    error ClaimTooSoon(uint256 nextClaimTime);
    error NoRewards();
    error InsufficientGBC(uint256 required, uint256 available);
    error InsufficientUSDT(uint256 required, uint256 available);
    error InvalidTokenAddress(address token);
    error InvalidTokenDecimals(uint8 decimals_);
    error CountMustBePositive();
    error IndexOutOfBounds(uint256 index, uint256 length);
    error NoSnapshots();
    error UpkeepNotNeeded(uint256 lastUpdateTime, uint256 currentTime);
    error ProtectedToken(address token);
    error RescueAmountTooLarge(uint256 requested, uint256 available);
    error ZeroAddress();
    error TransferAmountMismatch(uint256 expected, uint256 received);

    // ============ Token ============

    IERC20 public immutable USDT;
    IERC20 public immutable GBC;

    // ============ Mining Config ============

    uint256 public constant HASHRATE = 1e16;
    uint256 public constant BASICCOMPUTINGPOWER = 3e16;

    /// @notice 最短领奖间隔
    uint256 public constant TIMEINTERVAL = 24 hours;

    /// @notice Chainlink Automation 快照间隔
    uint256 public constant UPDATE_INTERVAL = 1 hours;

    /// @notice 最多保存最近 168 条快照，约 7 天，每小时一条
    uint256 public constant MAX_HISTORY_LENGTH = 168;

    /// @notice 每次质押单位：100 个 USDT，精度由 USDT decimals 动态确定
    uint256 public immutable STAKE_UNIT;

    // ============ Chainlink Snapshot ============

    uint256 public lastUpdateTime;

    struct HashPowerSnapshot {
        uint256 timestamp;
        uint256 totalHashPower;
        uint256 totalStakedUsdt;
        uint256 totalMiners;
        uint256 blockNumber;
    }

    HashPowerSnapshot[MAX_HISTORY_LENGTH] private _hashPowerHistory;
    uint256 private _nextSnapshotIndex;

    uint256 public hashPowerHistoryLength;
    uint256 public snapshotCounter;

    // ============ Global Mining State ============

    uint256 public totalStakedUsdt;
    uint256 public totalActiveMiners;
    uint256 public totalHashPower;

    // ============ Miner State ============

    struct Minter {
        bool isStartMint;
        uint256 startMintTime;
        uint256 totalUsdt;

        // lastMintTime 在这里表示“上次奖励记账时间”
        uint256 lastMintTime;

        // lastClaimTime 表示“上次成功领取奖励时间”
        uint256 lastClaimTime;

        // 已记账但尚未领取的 GBC 奖励
        uint256 accruedRewards;
    }

    mapping(address => Minter) public minter;
    address[] public minerAddresses;
    mapping(address => bool) public isMinerRegistered;

    // ============ Events ============

    event StartMint(
        address indexed owner,
        bool isStartMint,
        uint256 startMintTime,
        uint256 lastMintTime
    );

    event Staked(address indexed owner, uint256 amount, uint256 totalUsdt);
    event WithdrawRewards(address indexed owner, uint256 reward);
    event WithdrawStake(address indexed user, uint256 amount);

    event HashPowerUpdated(
        uint256 indexed snapshotId,
        uint256 timestamp,
        uint256 totalHashPower,
        uint256 totalStakedUsdt,
        uint256 totalMiners
    );

    event StakedViaTransferAndCall(
        address indexed from,
        address indexed operator,
        uint256 amount
    );

    event StakedViaApproveAndCall(address indexed from, uint256 amount);

    event RewardsFunded(address indexed from, uint256 amount);
    event TokenRescued(address indexed token, address indexed to, uint256 amount);

    // ============ Constructor ============

    constructor(
        address usdt_,
        address gbc_,
        address initialOwner_
    ) Ownable(initialOwner_) {
        if (usdt_ == address(0) || usdt_.code.length == 0) {
            revert InvalidTokenAddress(usdt_);
        }
        if (gbc_ == address(0) || gbc_.code.length == 0) {
            revert InvalidTokenAddress(gbc_);
        }
        if (initialOwner_ == address(0)) {
            revert ZeroAddress();
        }

        USDT = IERC20(usdt_);
        GBC = IERC20(gbc_);

        uint8 dec = IERC20Metadata(usdt_).decimals();

        // 防止 10 ** decimals 极端情况下溢出。正常 USDT 为 6，常见 ERC20 为 18。
        if (dec > 36) {
            revert InvalidTokenDecimals(dec);
        }

        STAKE_UNIT = 100 * (10 ** uint256(dec));

        lastUpdateTime = block.timestamp;
        _createHashPowerSnapshot();
    }

    // ============ ERC165 ============

    function supportsInterface(
        bytes4 interfaceId
    ) public view override(ERC165) returns (bool) {
        return
            interfaceId == type(IERC1363Receiver).interfaceId ||
            interfaceId == type(IERC1363Spender).interfaceId ||
            super.supportsInterface(interfaceId);
    }

    // ============ ERC1363 Receiver: transferAndCall ============

    function onTransferReceived(
        address operator,
        address from,
        uint256 value,
        bytes calldata
    ) external override nonReentrant whenNotPaused returns (bytes4) {
        if (msg.sender != address(USDT)) {
            revert OnlyUSDTAllowed(msg.sender);
        }

        // ERC1363 transferAndCall 已经先把 token 转入本合约。
        // 这里校验合约余额足以覆盖新增质押，避免恶意/异常 token 回调但未到账。
        uint256 requiredBalance = totalStakedUsdt + value;
        uint256 currentBalance = USDT.balanceOf(address(this));
        if (currentBalance < requiredBalance) {
            revert InsufficientUSDT(requiredBalance, currentBalance);
        }

        _stakeAccounting(from, value);

        emit StakedViaTransferAndCall(from, operator, value);

        return IERC1363Receiver.onTransferReceived.selector;
    }

    // ============ ERC1363 Spender: approveAndCall ============

    function onApprovalReceived(
        address owner_,
        uint256 value,
        bytes calldata
    ) external override nonReentrant whenNotPaused returns (bytes4) {
        if (msg.sender != address(USDT)) {
            revert OnlyUSDTAllowed(msg.sender);
        }

        _validateStake(owner_, value);

        uint256 beforeBalance = USDT.balanceOf(address(this));
        USDT.safeTransferFrom(owner_, address(this), value);
        uint256 afterBalance = USDT.balanceOf(address(this));

        uint256 received = afterBalance - beforeBalance;
        if (received != value) {
            revert TransferAmountMismatch(value, received);
        }

        _stakeAccounting(owner_, value);

        emit StakedViaApproveAndCall(owner_, value);

        return IERC1363Spender.onApprovalReceived.selector;
    }

    // ============ Chainlink Automation ============

    function checkUpkeep(
        bytes calldata
    )
        external
        view
        override
        returns (bool upkeepNeeded, bytes memory performData)
    {
        upkeepNeeded = _upkeepNeeded();
        performData = "";
    }

    function performUpkeep(bytes calldata) external override {
        if (!_upkeepNeeded()) {
            revert UpkeepNotNeeded(lastUpdateTime, block.timestamp);
        }

        lastUpdateTime = block.timestamp;
        _createHashPowerSnapshot();
    }

    function _upkeepNeeded() internal view returns (bool) {
        return block.timestamp >= lastUpdateTime + UPDATE_INTERVAL;
    }

    // ============ User Functions ============

    function startMint() external nonReentrant whenNotPaused {
        address user = msg.sender;
        Minter storage m = minter[user];

        if (m.isStartMint) {
            revert MiningAlreadyStarted(user);
        }

        m.isStartMint = true;
        m.startMintTime = block.timestamp;
        m.lastMintTime = block.timestamp;
        m.lastClaimTime = block.timestamp;

        _registerMiner(user);

        emit StartMint(user, true, m.startMintTime, m.lastMintTime);
    }

    function withdrawRewards() external nonReentrant whenNotPaused {
        _claimRewards(msg.sender);
    }

    /**
     * @notice 赎回质押 USDT。
     * @dev 即使 GBC 奖励池不足，用户也可以赎回本金。
     */
    function withdrawStakeUsdt(uint256 amount) external nonReentrant {
        address user = msg.sender;
        Minter storage m = minter[user];

        if (!m.isStartMint || m.startMintTime == 0) {
            revert MiningNotStarted(user);
        }

        if (amount == 0 || amount > m.totalUsdt) {
            revert InvalidWithdrawAmount(amount);
        }

        // 保持质押余额始终为 STAKE_UNIT 的整数倍；全部赎回除外。
        if (amount != m.totalUsdt && amount % STAKE_UNIT != 0) {
            revert InvalidWithdrawAmount(amount);
        }

        _accrueRewards(user);

        uint256 beforePower = getPower(user);
        bool wasActive = _isActiveStake(m.totalUsdt);

        m.totalUsdt -= amount;
        totalStakedUsdt -= amount;

        uint256 afterPower = getPower(user);
        bool isActive = _isActiveStake(m.totalUsdt);

        _replaceTotalPower(beforePower, afterPower);
        _syncActiveMinerCount(wasActive, isActive);

        uint256 balance = USDT.balanceOf(address(this));
        if (balance < amount) {
            revert InsufficientUSDT(amount, balance);
        }

        USDT.safeTransfer(user, amount);

        emit WithdrawStake(user, amount);
    }

    // ============ Reward Funding ============

    /**
     * @notice 给合约补充 GBC 奖励池。
     * @dev 奖励 token 不要求 ERC1363，普通 ERC20 approve + fundRewards 即可。
     */
    function fundRewards(uint256 amount) external nonReentrant {
        if (amount == 0) {
            revert InvalidAmount(amount);
        }

        uint256 beforeBalance = GBC.balanceOf(address(this));
        GBC.safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = GBC.balanceOf(address(this)) - beforeBalance;

        if (received == 0) {
            revert InvalidAmount(amount);
        }

        emit RewardsFunded(msg.sender, received);
    }

    // ============ View Functions ============

    function getPower(address user) public view returns (uint256) {
        Minter storage m = minter[user];

        if (!m.isStartMint) {
            return 0;
        }

        return _powerForStake(m.totalUsdt);
    }

    function pendingRewards(
        address user
    ) public view returns (uint256 reward, uint256 power) {
        Minter storage m = minter[user];

        if (!m.isStartMint || m.startMintTime == 0) {
            return (0, 0);
        }

        power = getPower(user);
        reward = m.accruedRewards;

        if (power > 0 && block.timestamp > m.lastMintTime) {
            reward += Math.mulDiv(
                power,
                block.timestamp - m.lastMintTime,
                1 hours
            );
        }
    }

    function claimableRewards(
        address user
    )
        external
        view
        returns (
            uint256 reward,
            uint256 power,
            bool claimable,
            uint256 nextClaimTime
        )
    {
        Minter storage m = minter[user];

        (reward, power) = pendingRewards(user);

        if (!m.isStartMint || m.startMintTime == 0) {
            return (0, 0, false, 0);
        }

        nextClaimTime = m.lastClaimTime + TIMEINTERVAL;
        claimable = block.timestamp >= nextClaimTime && reward > 0;
    }

    function getHashPowerHistoryLength() external view returns (uint256) {
        return hashPowerHistoryLength;
    }

    function getHashPowerSnapshot(
        uint256 index
    )
        external
        view
        returns (
            uint256 timestamp,
            uint256 _totalHashPower,
            uint256 _totalStakedUsdt,
            uint256 totalMiners,
            uint256 blockNumber
        )
    {
        HashPowerSnapshot memory s = _hashPowerHistory[
            _historyPhysicalIndex(index)
        ];

        return (
            s.timestamp,
            s.totalHashPower,
            s.totalStakedUsdt,
            s.totalMiners,
            s.blockNumber
        );
    }

    function getLatestHashPowerSnapshot()
        external
        view
        returns (
            uint256 timestamp,
            uint256 _totalHashPower,
            uint256 _totalStakedUsdt,
            uint256 totalMiners,
            uint256 blockNumber
        )
    {
        uint256 len = hashPowerHistoryLength;
        if (len == 0) {
            revert NoSnapshots();
        }

        HashPowerSnapshot memory s = _hashPowerHistory[
            _historyPhysicalIndex(len - 1)
        ];

        return (
            s.timestamp,
            s.totalHashPower,
            s.totalStakedUsdt,
            s.totalMiners,
            s.blockNumber
        );
    }

    function getRecentHashPowerSnapshots(
        uint256 count
    ) external view returns (HashPowerSnapshot[] memory) {
        if (count == 0) {
            revert CountMustBePositive();
        }

        uint256 len = hashPowerHistoryLength;
        uint256 n = count > len ? len : count;

        HashPowerSnapshot[] memory result = new HashPowerSnapshot[](n);

        uint256 start = len - n;
        for (uint256 i = 0; i < n; i++) {
            result[i] = _hashPowerHistory[_historyPhysicalIndex(start + i)];
        }

        return result;
    }

    function getCurrentTotalHashPower() external view returns (uint256) {
        return totalHashPower;
    }

    function getTotalMiners() external view returns (uint256) {
        return minerAddresses.length;
    }

    function getActiveMiners() external view returns (uint256) {
        return totalActiveMiners;
    }

    // ============ Owner Functions ============

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function manualUpdateHashPower() external onlyOwner {
        lastUpdateTime = block.timestamp;
        _createHashPowerSnapshot();
    }

    /**
     * @notice 救援非 USDT / 非 GBC 的误转 token。
     */
    function rescueToken(
        address token,
        address to,
        uint256 amount
    ) external onlyOwner nonReentrant {
        if (token == address(0) || token.code.length == 0) {
            revert InvalidTokenAddress(token);
        }
        if (to == address(0)) {
            revert ZeroAddress();
        }
        if (amount == 0) {
            revert InvalidAmount(amount);
        }
        if (token == address(USDT) || token == address(GBC)) {
            revert ProtectedToken(token);
        }

        IERC20(token).safeTransfer(to, amount);

        emit TokenRescued(token, to, amount);
    }

    /**
     * @notice 只允许提走 USDT 超额余额，不能提走用户质押本金。
     * @dev 超额余额通常来自误转或测试补偿。
     */
    function rescueStakeTokenSurplus(
        address to,
        uint256 amount
    ) external onlyOwner nonReentrant {
        if (to == address(0)) {
            revert ZeroAddress();
        }
        if (amount == 0) {
            revert InvalidAmount(amount);
        }

        uint256 balance = USDT.balanceOf(address(this));
        uint256 surplus = balance > totalStakedUsdt
            ? balance - totalStakedUsdt
            : 0;

        if (amount > surplus) {
            revert RescueAmountTooLarge(amount, surplus);
        }

        USDT.safeTransfer(to, amount);

        emit TokenRescued(address(USDT), to, amount);
    }

    // ============ Internal Accounting ============

    function _stakeAccounting(address user, uint256 amount) internal {
        _validateStake(user, amount);

        _accrueRewards(user);

        Minter storage m = minter[user];

        uint256 beforePower = getPower(user);
        bool wasActive = _isActiveStake(m.totalUsdt);

        m.totalUsdt += amount;
        totalStakedUsdt += amount;

        uint256 afterPower = getPower(user);
        bool isActive = _isActiveStake(m.totalUsdt);

        _replaceTotalPower(beforePower, afterPower);
        _syncActiveMinerCount(wasActive, isActive);

        emit Staked(user, amount, m.totalUsdt);
    }

    function _validateStake(address user, uint256 amount) internal view {
        if (user == address(0)) {
            revert ZeroAddress();
        }

        Minter storage m = minter[user];

        if (!m.isStartMint || m.startMintTime == 0) {
            revert MiningNotStarted(user);
        }

        if (amount == 0 || amount % STAKE_UNIT != 0) {
            revert InvalidStakeAmount(amount);
        }
    }

    function _claimRewards(address user) internal {
        Minter storage m = minter[user];

        if (!m.isStartMint || m.startMintTime == 0) {
            revert MiningNotStarted(user);
        }

        uint256 nextClaimTime = m.lastClaimTime + TIMEINTERVAL;
        if (block.timestamp < nextClaimTime) {
            revert ClaimTooSoon(nextClaimTime);
        }

        _accrueRewards(user);

        uint256 reward = m.accruedRewards;
        if (reward == 0) {
            revert NoRewards();
        }

        uint256 gbcBalance = GBC.balanceOf(address(this));
        if (gbcBalance < reward) {
            revert InsufficientGBC(reward, gbcBalance);
        }

        m.accruedRewards = 0;
        m.lastClaimTime = block.timestamp;

        GBC.safeTransfer(user, reward);

        emit WithdrawRewards(user, reward);
    }

    function _accrueRewards(address user) internal {
        Minter storage m = minter[user];

        if (!m.isStartMint || m.startMintTime == 0) {
            revert MiningNotStarted(user);
        }

        uint256 elapsed = block.timestamp - m.lastMintTime;
        if (elapsed == 0) {
            return;
        }

        uint256 power = getPower(user);
        if (power > 0) {
            m.accruedRewards += Math.mulDiv(power, elapsed, 1 hours);
        }

        m.lastMintTime = block.timestamp;
    }

    function _registerMiner(address minerAddr) internal {
        if (!isMinerRegistered[minerAddr]) {
            minerAddresses.push(minerAddr);
            isMinerRegistered[minerAddr] = true;
        }
    }

    function _powerForStake(uint256 stakeAmount) internal view returns (uint256) {
        uint256 units = stakeAmount / STAKE_UNIT;

        if (units == 0) {
            return 0;
        }

        return BASICCOMPUTINGPOWER + units * HASHRATE;
    }

    function _isActiveStake(uint256 stakeAmount) internal view returns (bool) {
        return stakeAmount / STAKE_UNIT > 0;
    }

    function _replaceTotalPower(
        uint256 beforePower,
        uint256 afterPower
    ) internal {
        if (afterPower >= beforePower) {
            totalHashPower += afterPower - beforePower;
        } else {
            totalHashPower -= beforePower - afterPower;
        }
    }

    function _syncActiveMinerCount(bool wasActive, bool isActive) internal {
        if (!wasActive && isActive) {
            totalActiveMiners += 1;
        } else if (wasActive && !isActive) {
            totalActiveMiners -= 1;
        }
    }

    function _createHashPowerSnapshot() internal {
        HashPowerSnapshot memory snapshot = HashPowerSnapshot({
            timestamp: block.timestamp,
            totalHashPower: totalHashPower,
            totalStakedUsdt: totalStakedUsdt,
            totalMiners: totalActiveMiners,
            blockNumber: block.number
        });

        uint256 writeIndex = _nextSnapshotIndex;

        _hashPowerHistory[writeIndex] = snapshot;
        _nextSnapshotIndex = (writeIndex + 1) % MAX_HISTORY_LENGTH;

        if (hashPowerHistoryLength < MAX_HISTORY_LENGTH) {
            hashPowerHistoryLength += 1;
        }

        emit HashPowerUpdated(
            snapshotCounter,
            snapshot.timestamp,
            snapshot.totalHashPower,
            snapshot.totalStakedUsdt,
            snapshot.totalMiners
        );

        unchecked {
            snapshotCounter += 1;
        }
    }

    function _historyPhysicalIndex(
        uint256 index
    ) internal view returns (uint256) {
        uint256 len = hashPowerHistoryLength;

        if (index >= len) {
            revert IndexOutOfBounds(index, len);
        }

        if (len < MAX_HISTORY_LENGTH) {
            return index;
        }

        // 当环形缓冲区已满时，_nextSnapshotIndex 指向最老的一条记录。
        return (_nextSnapshotIndex + index) % MAX_HISTORY_LENGTH;
    }
}